#!/usr/bin/env bash
# Regression tests for lib/jira-adf.py (markdown-ish -> ADF).
#
# Run from the plugin root:
#   bash plugins/jira/tests/test-jira-adf.sh

set -uo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd)
converter="$script_dir/../lib/jira-adf.py"
failures=0
total=0

py=""
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then py="$candidate"; break; fi
done
[[ -n "$py" ]] || { echo "no python found"; exit 1; }

fixture=$(mktemp)
cat > "$fixture" <<'MD'
**Causa:** o `DELETE` na wp_options não alcança o Redis. Precedente ENG-4809, veja
[**SUP-1941**](https://example.atlassian.net/browse/SUP-1941) e [MR !29](https://git.example/mr/29).

- item um com ENG-5056
- item dois

1. primeiro
2. segundo

## Título

```bash
echo "hi"

echo "blank line kept"
```

[[SUCCESS]]
**Aviso ao cliente**

Texto para o cliente.

[[/PANEL]]

Parágrafo depois do painel.

Oi @[Ana Silva](0123456789abcdef01234567), olha isso. @Beltrano fica texto.
MD

check() {
  local name="$1" expr="$2" json="$3"
  total=$((total + 1))
  if printf '%s' "$json" | "$py" -c "import sys, json; d = json.load(sys.stdin); sys.exit(0 if ($expr) else 1)"; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    failures=$((failures + 1))
  fi
}

json=$("$py" "$converter" --base-url https://example.atlassian.net/ --projects SUP,ENG --wrap comment "$fixture")

check "wrap comment has body.doc" "d['body']['type'] == 'doc' and d['body']['version'] == 1" "$json"
check "first paragraph starts with strong Causa:" "d['body']['content'][0]['type'] == 'paragraph' and d['body']['content'][0]['content'][0]['marks'][0]['type'] == 'strong'" "$json"
check "code mark on DELETE" "any(n.get('marks',[{}])[0].get('type') == 'code' and n['text'] == 'DELETE' for n in d['body']['content'][0]['content'])" "$json"
check "bare ENG-4809 becomes a link" "any(n['text'] == 'ENG-4809' and any(m['type']=='link' and m['attrs']['href'].endswith('/browse/ENG-4809') for m in n.get('marks',[])) for n in d['body']['content'][0]['content'])" "$json"
check "[**SUP-1941**](url) keeps bold and link" "any(n['text'] == 'SUP-1941' and {m['type'] for m in n.get('marks',[])} == {'link','strong'} for n in d['body']['content'][0]['content'])" "$json"
check "markdown link MR !29" "any(n['text'] == 'MR !29' and n['marks'][0]['attrs']['href'] == 'https://git.example/mr/29' for n in d['body']['content'][0]['content'])" "$json"
check "bullet list with 2 items" "d['body']['content'][1]['type'] == 'bulletList' and len(d['body']['content'][1]['content']) == 2" "$json"
check "key inside bullet is linked" "any(m['type']=='link' for n in d['body']['content'][1]['content'][0]['content'][0]['content'] for m in n.get('marks',[]))" "$json"
check "ordered list" "d['body']['content'][2]['type'] == 'orderedList' and len(d['body']['content'][2]['content']) == 2" "$json"
check "heading level 2" "d['body']['content'][3]['type'] == 'heading' and d['body']['content'][3]['attrs']['level'] == 2" "$json"
check "code block keeps blank line and language" "d['body']['content'][4]['type'] == 'codeBlock' and d['body']['content'][4]['attrs']['language'] == 'bash' and '\n\n' in d['body']['content'][4]['content'][0]['text']" "$json"
check "success panel with 2 paragraphs" "d['body']['content'][5]['type'] == 'panel' and d['body']['content'][5]['attrs']['panelType'] == 'success' and len(d['body']['content'][5]['content']) == 2" "$json"
check "paragraph after panel is outside it" "d['body']['content'][6]['type'] == 'paragraph' and len(d['body']['content']) == 8" "$json"
check "@[Name](id) becomes a mention node" "any(n.get('type') == 'mention' and n['attrs']['id'] == '0123456789abcdef01234567' and n['attrs']['text'] == '@Ana Silva' for n in d['body']['content'][7]['content'])" "$json"
check "plain @Name stays text" "any(n.get('type') == 'text' and '@Beltrano' in n['text'] for n in d['body']['content'][7]['content'])" "$json"

desc=$("$py" "$converter" --wrap description "$fixture")
check "wrap description is the bare doc" "d['type'] == 'doc'" "$desc"

keys=$("$py" "$converter" --projects SUP,ENG --keys "$fixture" | tr '\n' ' ')
total=$((total + 1))
if [[ "$keys" == "ENG-4809 SUP-1941 ENG-5056 " ]]; then echo "ok   - --keys lists distinct keys in order"; else echo "FAIL - --keys gave: $keys"; failures=$((failures + 1)); fi

marker=$("$py" "$converter" --marker "$fixture")
total=$((total + 1))
if [[ "$marker" == Causa:* ]]; then echo "ok   - --marker prints first paragraph text"; else echo "FAIL - --marker gave: $marker"; failures=$((failures + 1)); fi

rm -f "$fixture"
echo "$((total - failures))/$total passed"
[[ $failures -eq 0 ]]
