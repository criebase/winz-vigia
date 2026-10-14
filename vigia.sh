#!/usr/bin/env bash
# Vigia de fora. Roda no GitHub Actions (.github/workflows/vigia.yml, a cada 10 minutos), longe da VPS e longe do WhatsApp:
# se a VPS cai, o vigia.sh, o painel e o aviso pelo WhatsApp caem juntos; este não.
#
# Lê o endereço público de saúde (app.winz.com.br/saude/<VIGIA_TOKEN>.json) e FALHA quando:
#   - o endereço não responde, ou a resposta não é o JSON esperado;
#   - o painel não atualiza o arquivo há mais de 15 minutos (quem grava o arquivo parou);
#   - o WhatsApp está desligado (whatsapp = "desligado");
#   - o relógio dos pedidos não bate há mais de 25 minutos (relogio_minutos);
#   - o canário de hoje falhou (canario = "falhou") ou não roda há mais de 30 horas (canario = "atrasado").
# Não falha por "sem_registro" (canário ainda não ligado), por "desconhecido" (a Evolution não respondeu ao painel) nem por relogio_minutos nulo
# (relógio desligado ou sem batimento ainda).
#
# Só falha na virada, de bom para ruim: o GitHub manda e-mail de run que falha, então enquanto o problema continua as passadas seguintes
# passam (com aviso na tela da execução) e nada chega à caixa de entrada. Quando melhora, volta a passar; se piorar de novo, falha de novo.
# A memória de "bom ou ruim" é o arquivo VIGIA_ESTADO, que o workflow guarda entre as execuções (actions/cache).
#
# Entradas (variáveis):
#   VIGIA_URL      o endereço completo, com o token (segredo do GitHub: nunca é impresso)
#   VIGIA_ESTADO   arquivo com "bom" ou "ruim" da passada anterior (padrão: vigia-estado.txt); sem ele vale "bom"
# Saída: 0 passou (ou o problema já tinha sido avisado), 1 virou ruim agora.
#
#   vigia-de-fora.sh --ensaio   não toca em rede: roda os casos abaixo contra arquivos locais e imprime "== N ok, M falharam =="
#     VIGIA_ARQUIVO  (só no ensaio) arquivo JSON no lugar do endereço
#     VIGIA_FALHA    (só no ensaio) simula o endereço fora do ar
#     VIGIA_AGORA    (só no ensaio) o "agora" em epoch
set -uo pipefail

# O Python da máquina: python3 no GitHub Actions; no Windows, o que responder.
export PYTHONIOENCODING=utf-8 PYTHONUTF8=1
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys' >/dev/null 2>&1; then PY=$c; break; fi
done
[ -n "$PY" ] || { echo "vigia-de-fora: sem python nesta máquina" >&2; exit 2; }

# Os motivos pelos quais o estado é ruim, um por linha (nada, se está tudo bem). $1 = arquivo JSON, $2 = agora (epoch).
motivos() {
  "$PY" - "$1" "$2" <<'PYEOF'
import json, sys
from datetime import datetime
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    assert isinstance(d, dict)
except Exception:
    print("a resposta do endereço de saúde não é o JSON esperado")
    sys.exit(0)
agora = float(sys.argv[2])
m = []
if d.get("whatsapp") == "desligado":
    m.append("o WhatsApp da Winz está desligado")
r = d.get("relogio_minutos")
if isinstance(r, (int, float)) and not isinstance(r, bool) and r > 25:
    m.append(f"o relógio dos pedidos não bate há {int(r)} minutos (limite: 25)")
if d.get("canario") == "falhou":
    m.append("o canário de hoje falhou (o cliente de mentira não passou pelo Hugo)")
if d.get("canario") == "atrasado":
    m.append("o canário não roda há mais de 30 horas")
try:
    idade = (agora - datetime.fromisoformat(str(d["gerado_em"]).replace("Z", "+00:00")).timestamp()) / 60
except Exception:
    m.append("o endereço de saúde não traz gerado_em legível")
else:
    if idade > 15:
        m.append(f"o painel não atualiza há {int(idade)} minutos")
if not m and d.get("ok") is False:
    m.append("o endereço de saúde diz ok=false")
print("\n".join(m))
PYEOF
}

# Busca o endereço para o arquivo $1. Devolve 0, ou 1 com o motivo (sem o endereço, que leva o segredo) em $1.erro.
buscar() {
  if [ -n "${VIGIA_ARQUIVO:-}${VIGIA_FALHA:-}" ]; then   # ensaio
    [ -n "${VIGIA_FALHA:-}" ] && { echo "curl: (22) The requested URL returned error: 404" > "$1.erro"; return 1; }
    cp "$VIGIA_ARQUIVO" "$1"; return 0
  fi
  [ -n "${VIGIA_URL:-}" ] || { echo "VIGIA_URL não definida (falta o segredo VIGIA_TOKEN no GitHub)" > "$1.erro"; return 1; }
  curl -sS --fail --max-time 20 --retry 3 --retry-delay 5 --retry-all-errors -o "$1" "$VIGIA_URL" 2> "$1.erro" || return 1
}

passada() {
  local estado_arq=${VIGIA_ESTADO:-vigia-estado.txt} corpo agora lista anterior
  corpo=$(mktemp); agora=${VIGIA_AGORA:-$(date +%s)}
  if buscar "$corpo"; then
    lista=$(motivos "$corpo" "$agora")
  else
    lista="o endereço de saúde não responde ($(sed -E 's#https?://[^ ]*#<endereço>#g' "$corpo.erro" | head -c 200 | tr '\n' ' '))"
  fi
  rm -f "$corpo" "$corpo.erro"
  if [ -z "$lista" ]; then
    echo bom > "$estado_arq"
    echo "Winz respirando: WhatsApp ligado, relógio batendo, canário sem falha."
    return 0
  fi
  anterior=$(cat "$estado_arq" 2>/dev/null || echo bom)
  echo ruim > "$estado_arq"
  if [ "$anterior" = ruim ]; then
    echo "::warning title=Winz continua fora do normal::$(echo "$lista" | tr '\n' ';') (o e-mail já foi na virada)"
    echo "Continua ruim; o aviso já saiu quando virou:"; echo "$lista"
    return 0
  fi
  echo "::error title=Winz fora do normal::$(echo "$lista" | tr '\n' ';')"
  echo "Virou ruim agora:"; echo "$lista"
  return 1
}

# --- ensaio ------------------------------------------------------------------------------------------------------------------------------
ensaio() {
  local dir ok=0 ruim=0 agora=1792000000 saida cod
  dir=$(mktemp -d); trap 'rm -rf "$dir"' RETURN
  local self; self=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
  # gerado_em de "x minutos atrás" em relação ao agora do ensaio, em horário de Brasília
  gerado() { "$PY" -c 'import sys;from datetime import datetime,timedelta,timezone;print((datetime.fromtimestamp(float(sys.argv[1]),timezone(timedelta(hours=-3)))-timedelta(minutes=float(sys.argv[2]))).isoformat(timespec="seconds"))' "$agora" "$1"; }
  saude() {   # saude <whatsapp> <relogio|null> <canario> <idade em minutos>
    printf '{"ok": true, "gerado_em": "%s", "whatsapp": "%s", "relogio_minutos": %s, "canario": "%s"}\n' "$(gerado "$4")" "$1" "$2" "$3" > "$dir/saude.json"
  }
  rodar() {   # rodar <anterior bom|ruim|nenhum>; usa $dir/saude.json (ou VIGIA_FALHA) e deixa a saída em $saida e o código em $cod
    [ "$1" = nenhum ] && rm -f "$dir/estado" || echo "$1" > "$dir/estado"
    if [ "${2:-}" = sem_segredo ]; then
      saida=$(env -u VIGIA_ARQUIVO -u VIGIA_FALHA -u VIGIA_URL VIGIA_ESTADO="$dir/estado" VIGIA_AGORA=$agora bash "$self" 2>&1); cod=$?
    else
      saida=$(env VIGIA_ARQUIVO="$dir/saude.json" VIGIA_ESTADO="$dir/estado" VIGIA_AGORA=$agora VIGIA_URL="https://exemplo.invalido/saude/SEGREDO_DO_ENSAIO.json" ${2:+"$2"} bash "$self" 2>&1); cod=$?
    fi
  }
  deve() {   # deve <nome> <condição>
    if eval "$2"; then ok=$((ok+1)); echo "  ok        $1"; else ruim=$((ruim+1)); echo "  FALHOU    $1  [código $cod] $saida"; fi
  }
  saude ok 4 ok 1;           rodar bom;      deve "tudo bem: passa e fica bom" '[ $cod = 0 ] && [ "$(cat $dir/estado)" = bom ]'
  saude ok null sem_registro 1; rodar nenhum; deve "sem estado anterior vale bom; relógio nulo e canário sem registro não falham" '[ $cod = 0 ]'
  saude desconhecido 4 ok 1;  rodar bom;      deve "WhatsApp desconhecido (a Evolution não respondeu ao painel) não falha" '[ $cod = 0 ]'
  saude desligado 4 ok 1;    rodar bom;      deve "WhatsApp desligado: falha na virada e fica ruim" '[ $cod = 1 ] && [ "$(cat $dir/estado)" = ruim ] && echo "$saida" | grep -q "WhatsApp"'
  saude desligado 4 ok 1;    rodar ruim;     deve "continua desligado: passa, com aviso, sem novo e-mail" '[ $cod = 0 ] && [ "$(cat $dir/estado)" = ruim ] && echo "$saida" | grep -q "::warning"'
  saude ok 4 ok 1;           rodar ruim;     deve "melhorou: passa e volta a bom" '[ $cod = 0 ] && [ "$(cat $dir/estado)" = bom ]'
  saude desligado 4 ok 1;    rodar bom;      deve "piorou de novo depois de melhorar: falha de novo" '[ $cod = 1 ]'
  saude ok 25 ok 1;          rodar bom;      deve "relógio há 25 minutos ainda passa" '[ $cod = 0 ]'
  saude ok 26 ok 1;          rodar bom;      deve "relógio há 26 minutos falha" '[ $cod = 1 ] && echo "$saida" | grep -q "relógio"'
  saude ok 4 falhou 1;       rodar bom;      deve "canário de hoje falhou: falha" '[ $cod = 1 ] && echo "$saida" | grep -q "canário"'
  saude ok 4 atrasado 1;     rodar bom;      deve "canário parado há mais de 30 horas: falha" '[ $cod = 1 ]'
  saude ok 4 ok 20;          rodar bom;      deve "painel sem atualizar há 20 minutos: falha" '[ $cod = 1 ] && echo "$saida" | grep -q "painel"'
  saude desligado 40 falhou 1; rodar bom;    deve "vários problemas juntos: um aviso só, com todos" '[ $cod = 1 ] && [ "$(echo "$saida" | grep -c "::error")" = 1 ] && echo "$saida" | grep -q "WhatsApp" && echo "$saida" | grep -q "relógio" && echo "$saida" | grep -q "canário"'
  rodar bom VIGIA_FALHA=1;                   deve "endereço fora do ar: falha, sem imprimir o endereço nem o segredo" '[ $cod = 1 ] && echo "$saida" | grep -q "não responde" && ! echo "$saida" | grep -q "SEGREDO_DO_ENSAIO" && ! echo "$saida" | grep -q "exemplo.invalido"'
  rodar ruim VIGIA_FALHA=1;                  deve "endereço continua fora do ar: não repete o e-mail" '[ $cod = 0 ]'
  echo "isto não é json" > "$dir/saude.json"; rodar bom; deve "resposta que não é JSON: falha" '[ $cod = 1 ] && echo "$saida" | grep -q "JSON"'
  echo '{"ok": true}' > "$dir/saude.json";    rodar bom; deve "JSON sem gerado_em: falha" '[ $cod = 1 ]'
  saude ok 4 ok 1; rodar bom sem_segredo; deve "sem o segredo configurado: falha dizendo o que falta" '[ $cod = 1 ] && echo "$saida" | grep -q "VIGIA_TOKEN"'
  echo; echo "== $ok ok, $ruim falharam =="
  [ "$ruim" = 0 ]
}

if [ "${1:-}" = "--ensaio" ]; then ensaio; exit $?; fi
passada
