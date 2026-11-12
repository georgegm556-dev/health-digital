"""Separa los diseños por TIPO de dispositivo (no solo por ancho) y arma la página publicable.

Uso:
  python3 dispositivo.py css  <archivo.html>          # ajusta los media queries en el archivo (idempotente)
  python3 dispositivo.py build <fuente.html> <salida.html> <url> <key> [pruebas]
"""
import sys, re

TABLET = '@media (min-width:768px) and (min-height:560px)'          # celular acostado (poca altura) sigue en diseño de celular
PC = '(min-width:1100px) and (hover:hover) and (pointer:fine)'     # computadora: pantalla ancha con mouse o trackpad

DETECTOR = """<script>
/* Detecta el tipo de dispositivo y lo deja en <html data-disp="movil|tablet|pc"> (el CSS usa las mismas reglas). */
(function(){var h=document.documentElement,mq=function(q){return window.matchMedia&&matchMedia(q).matches};
function fija(){h.setAttribute('data-disp',mq('%s')?'pc':mq('(min-width:768px) and (min-height:560px)')?'tablet':'movil')}
fija();addEventListener('resize',fija);addEventListener('orientationchange',fija)})();
</script>""" % PC

def css(s):
    s = s.replace('@media (min-width:768px){', TABLET + '{')
    s = s.replace('@media (min-width:1100px){', '@media ' + PC + '{')
    s = s.replace('@media (min-width:1100px) and (max-width:1279px){', '@media ' + PC + ' and (max-width:1279px){')
    s = s.replace('@media (min-width:1100px) and (prefers-reduced-motion:reduce){', '@media ' + PC + ' and (prefers-reduced-motion:reduce){')
    if 'data-disp' not in s:
        s = s.replace('<meta name="claude:viewport-fit-sides" content="cover">', '<meta name="claude:viewport-fit-sides" content="cover">\n' + DETECTOR, 1)
    assert '@media (min-width:768px){' not in s and '@media (min-width:1100px){' not in s
    return s

HEAD = ('<!doctype html>\n<html lang="es">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">\n'
        '<meta name="theme-color" content="#0E7C8C">\n<meta name="format-detection" content="telephone=no">\n')

def build(src, url, key, pruebas=False):
    s = css(src)
    s = re.sub(r"  SUPABASE_URL: '[^']*',", "  SUPABASE_URL: '%s'," % url, s, count=1)
    s = re.sub(r"  SUPABASE_ANON_KEY: '[^']*',", "  SUPABASE_ANON_KEY: '%s'," % key, s, count=1)
    if pruebas:
        s = s.replace('<title>Health Digital</title>', '<title>Health Digital · PRUEBAS</title>\n<meta name="robots" content="noindex,nofollow">', 1)
        s += ('\n<div aria-hidden="true" style="position:fixed;top:0;left:50%;transform:translateX(-50%);z-index:9999;background:#B45309;color:#fff;'
              'font:600 11px/1.4 system-ui,sans-serif;padding:2px 10px;border-radius:0 0 8px 8px;pointer-events:none;letter-spacing:.04em">'
              'PROYECTO DE PRUEBAS · datos ficticios</div>\n')
    if not s.lstrip().lower().startswith('<!doctype'):
        s = HEAD + s
    assert url in s and key in s
    return s

if __name__ == '__main__':
    if sys.argv[1] == 'css':
        p = sys.argv[2]; t = open(p, encoding='utf-8').read(); open(p, 'w', encoding='utf-8').write(css(t)); print('css ok', p)
    else:
        src, out, url, key = sys.argv[2:6]
        t = build(open(src, encoding='utf-8').read(), url, key, len(sys.argv) > 6)
        open(out, 'w', encoding='utf-8').write(t); print('build ok', out)
