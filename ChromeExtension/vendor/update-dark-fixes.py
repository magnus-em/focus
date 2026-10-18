"""Regenerate bundled Dark Reader fixes; same version/license as darkreader.js."""
import hashlib
import json
from pathlib import Path
import re
import urllib.request

VERSION = '4.9.133'
URL = f'https://raw.githubusercontent.com/darkreader/darkreader/v{VERSION}/src/config/dynamic-theme-fixes.config'
COMMANDS = {'INVERT': 'invert', 'CSS': 'css', 'IGNORE INLINE STYLE': 'ignoreInlineStyle',
            'IGNORE IMAGE ANALYSIS': 'ignoreImageAnalysis', 'IGNORE CSS URL': 'ignoreCSSUrl'}


def generate(text):
    entries = []
    for block in re.split(r'^={2,}\s*$', text, flags=re.M):
        entry = {'url': []}
        command = 'url'
        values = []
        for line in block.strip().splitlines():
            if line.strip() in COMMANDS:
                entry[command] = '\n'.join(values).strip() if command == 'css' else [v.strip() for v in values if v.strip()]
                command = COMMANDS[line.strip()]
                values = []
            else:
                values.append(line)
        entry[command] = '\n'.join(values).strip() if command == 'css' else [v.strip() for v in values if v.strip()]
        if entry['url']:
            entries.append(entry)
    return entries


if __name__ == '__main__':
    raw = urllib.request.urlopen(URL).read()
    Path(__file__).with_name('darkreader-fixes.json').write_text(json.dumps(generate(raw.decode()), separators=(',', ':')) + '\n')
    print(f'{URL}\nSHA256 {hashlib.sha256(raw).hexdigest()}')
