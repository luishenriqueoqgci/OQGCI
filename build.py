"""Gera a prévia (artifact) e o site de produção a partir de src/app.html.

Uso: python3 build.py
- preview/diagnostico-oqgci.html : fragmento para publicar como prévia
- public/index.html              : página completa para o Netlify
"""
from pathlib import Path

ROOT = Path(__file__).parent
src = (ROOT / "src" / "app.html").read_text(encoding="utf-8")

(ROOT / "preview").mkdir(exist_ok=True)
(ROOT / "preview" / "diagnostico-oqgci.html").write_text(src, encoding="utf-8")

head_part, body_part = src.split('<div id="app"></div>', 1)
head_part = head_part.replace('<meta name="claude:viewport-fit-sides" content="cover">\n', "")

head = f"""<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="description" content="Diagnóstico de vendas com base em neurociência: Índice OQGCI, perfil e trilha de 30 dias.">
<meta name="theme-color" content="#0F0E14">
<link rel="manifest" href="manifest.webmanifest">
<link rel="icon" type="image/png" href="icons/icon-192.png">
<link rel="apple-touch-icon" href="icons/apple-touch-icon.png">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="OQGCI">
<style>:root{{padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}}body{{margin:0}}img{{max-width:100%}}[hidden]{{display:none!important}}</style>
<script src="config.js"></script>
{head_part}</head>
<body>
<div id="app"></div>{body_part}
<script>
if ('serviceWorker' in navigator) {{
  window.addEventListener('load', () => navigator.serviceWorker.register('sw.js').catch(() => {{}}));
}}
</script>
</body>
</html>
"""
(ROOT / "public" / "index.html").write_text(head, encoding="utf-8")
print("preview/diagnostico-oqgci.html e public/index.html gerados")
