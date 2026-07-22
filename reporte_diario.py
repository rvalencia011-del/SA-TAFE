"""
reporte_diario.py
Genera el reporte diario de FIBRAs con:
- Precios de cierre: Yahoo Finance
- Dividendos reales: Bolsapp (BMV)
- Portafolio óptimo: Simulated Annealing (run_sa.py)
"""

import json, math, random, subprocess, sys
from datetime import datetime, timedelta
from playwright.sync_api import sync_playwright

# ── Configuración ──────────────────────────────────────────────────────────
BOLSAPP_IDS = json.load(open("/app/state/01ea7918-f31e-4448-8b44-6a2ebf1e9da6/work/SA_TAFE/bolsapp_ids.json"))

FIBRAS_YAHOO = {
    'DANHOS13.MX':  'FIBRA Danhos',
    'FIBRAMQ12.MX': 'FIBRA Macquarie',
    'FIBRAPL14.MX': 'FIBRA Prologis',
    'FIHO12.MX':    'FIBRA Hotel',
    'FINN13.MX':    'FIBRA Inn',
    'FMTY14.MX':    'FIBRA Monterrey',
    'FPLUS16.MX':   'FIBRA Plus',
    'FSHOP13.MX':   'FIBRA Shop',
    'FUNO11.MX':    'FIBRA Uno',
    'FIBRAHD15.MX': 'FIBRA HD',
    'STORAGE18.MX': 'FIBRA Storage',
    'FHIPO14.MX':   'FIBRA Hipotecaria',
    'FNOVA17.MX':   'FIBRA Nova',
    'FIBRATC14.MX': 'FIBRA TC',
    'FCFE18.MX':    'FIBRA CF',
}

# ── 1. Precios desde Yahoo Finance ─────────────────────────────────────────
def get_precios_yahoo():
    try:
        import yfinance as yf
        precios = {}
        for ticker, nombre in FIBRAS_YAHOO.items():
            try:
                t = yf.Ticker(ticker)
                info = t.info
                precio = info.get('currentPrice') or info.get('regularMarketPrice') or info.get('previousClose')
                max52 = info.get('fiftyTwoWeekHigh')
                payout = info.get('payoutRatio')
                precios[ticker.replace('.MX','')] = {
                    'nombre': nombre,
                    'precio': precio,
                    'max52': max52,
                    'payout': payout,
                }
            except:
                pass
        return precios
    except Exception as e:
        print(f"[Yahoo] Error: {e}")
        return {}

# ── 2. Dividendos reales desde Bolsapp ────────────────────────────────────
def get_dividendos_bolsapp(username, password):
    divs = {}
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        ctx = browser.new_context()
        page = ctx.new_page()

        # Login
        page.goto("https://app.bolsapp.com.mx")
        page.wait_for_selector("input[type='email'], textbox", timeout=15000)
        page.fill("input[type='email']", username)
        page.fill("input[type='password']", password)
        page.keyboard.press("Enter")
        page.wait_for_url("**/app/home", timeout=15000)
        print("[Bolsapp] Login OK")

        for ticker_base, bolsapp_id in BOLSAPP_IDS.items():
            try:
                url = f"https://app.bolsapp.com.mx/#/app/issuerProfile/{bolsapp_id}/dividends"
                page.goto(url)
                page.wait_for_timeout(2500)

                # Extraer filas de la tabla de distribuciones
                rows = page.query_selector_all("table tr")
                pagos = []
                for row in rows:
                    celdas = row.query_selector_all("td")
                    if len(celdas) >= 2:
                        fecha_txt = celdas[0].inner_text().strip()
                        importe_txt = celdas[1].inner_text().strip().replace("MXN $","").replace(",","")
                        try:
                            # Parsear fecha en español
                            meses = {"enero":1,"febrero":2,"marzo":3,"abril":4,"mayo":5,
                                     "junio":6,"julio":7,"agosto":8,"septiembre":9,
                                     "octubre":10,"noviembre":11,"diciembre":12}
                            partes = fecha_txt.lower().replace(" de "," ").split()
                            if len(partes) == 3:
                                dia, mes_txt, anio = int(partes[0]), meses.get(partes[1],0), int(partes[2])
                                fecha = datetime(anio, mes_txt, dia)
                                importe = float(importe_txt)
                                pagos.append((fecha, importe))
                        except:
                            pass

                # Sumar últimos 12 meses
                hace_12m = datetime.today() - timedelta(days=365)
                div_12m = sum(imp for (f, imp) in pagos if f >= hace_12m)
                if div_12m > 0:
                    divs[ticker_base] = round(div_12m, 4)
                    print(f"[Bolsapp] {ticker_base}: div 12m = ${div_12m:.4f}")
            except Exception as e:
                print(f"[Bolsapp] {ticker_base}: ERROR {e}")

        browser.close()
    return divs

# ── 3. Correr Simulated Annealing ─────────────────────────────────────────
def get_portafolio_sa():
    try:
        result = subprocess.run(
            ["python3", "/app/state/01ea7918-f31e-4448-8b44-6a2ebf1e9da6/work/SA_TAFE/run_sa.py"],
            capture_output=True, text=True, timeout=120
        )
        out = result.stdout
        # Parsear resultados
        sharpe, rendimiento, riesgo = None, None, None
        pesos = {}
        for line in out.split('\n'):
            if 'Sharpe:' in line and sharpe is None:
                try: sharpe = float(line.split(':')[1].strip())
                except: pass
            if 'Rendimiento:' in line and rendimiento is None:
                try: rendimiento = line.split(':')[1].strip()
                except: pass
            if 'Riesgo:' in line and riesgo is None:
                try: riesgo = line.split(':')[1].strip()
                except: pass
            # Líneas de activos: "  FNOVA17.MX   52.0%"
            if '%' in line and '.MX' in line:
                parts = line.strip().split()
                if len(parts) == 2:
                    ticker = parts[0].replace('.MX','')
                    peso = parts[1]
                    pesos[ticker] = peso
        return sharpe, rendimiento, riesgo, pesos
    except Exception as e:
        print(f"[SA] Error: {e}")
        return None, None, None, {}

# ── 4. Construir reporte ───────────────────────────────────────────────────
def construir_reporte(precios, divs, sharpe, rendimiento, riesgo, pesos):
    hoy = datetime.today().strftime("%d/%m/%Y")
    dia_semana = ["Lunes","Martes","Miércoles","Jueves","Viernes","Sábado","Domingo"][datetime.today().weekday()]

    lineas = []
    lineas.append(f"📊 *DIVIDEND YIELD FORWARD — FIBRAS INMOBILIARIAS*")
    lineas.append(f"📅 {dia_semana} {hoy} | Cierre BMV")
    lineas.append("")
    lineas.append(f"{'Ticker':<12} {'Precio':>7} {'Div 12m':>8} {'Yield':>7} {'Payout':>7} {'vs Max52':>9}")
    lineas.append("─" * 55)

    for ticker_base, datos in sorted(precios.items(), key=lambda x: -(
        (divs.get(x[0], 0) / x[1]['precio'] * 100) if (x[1]['precio'] and divs.get(x[0])) else 0
    )):
        precio = datos.get('precio')
        max52 = datos.get('max52')
        payout = datos.get('payout')
        div = divs.get(ticker_base)

        if not precio:
            continue

        yield_str = f"{div/precio*100:.2f}%" if div else "N/D"
        div_str   = f"${div:.2f}" if div else "N/D"
        payout_str = f"{round(payout*100)}%" if payout else "N/D"
        dist_max = f"{((precio/max52)-1)*100:.1f}%" if max52 and precio else "N/D"

        lineas.append(f"{ticker_base:<12} ${precio:>6.2f} {div_str:>8} {yield_str:>7} {payout_str:>7} {dist_max:>9}")

    lineas.append("")
    lineas.append("🤖 *PORTAFOLIO ÓPTIMO SA-TAFE*")
    if sharpe:
        lineas.append(f"Sharpe: {sharpe} | Rend: {rendimiento} | Riesgo: {riesgo}")
        lineas.append("")
        for ticker, peso in sorted(pesos.items(), key=lambda x: -float(x[1].replace('%',''))):
            lineas.append(f"  {ticker:<14} {peso}")
    else:
        lineas.append("(Sin datos SA hoy)")

    lineas.append("")
    lineas.append("─" * 55)
    lineas.append("Fuente: Yahoo Finance + Bolsapp (BMV)")
    lineas.append("⚠️ No es recomendación de inversión.")

    return "\n".join(lineas)

# ── Main ───────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import os
    username = os.environ.get("BOLSAPP_USER", "")
    password = os.environ.get("BOLSAPP_PASS", "")

    print("Obteniendo precios Yahoo Finance...")
    precios = get_precios_yahoo()

    if username and password:
        print("Obteniendo dividendos Bolsapp...")
        divs = get_dividendos_bolsapp(username, password)
    else:
        # Fallback: calcular yield con dividendRate de Yahoo
        print("[!] Sin credenciales Bolsapp, usando Yahoo para dividendos")
        import yfinance as yf
        divs = {}
        for ticker in FIBRAS_YAHOO:
            try:
                info = yf.Ticker(ticker).info
                d = info.get('dividendRate')
                if d:
                    divs[ticker.replace('.MX','')] = d
            except:
                pass

    print("Corriendo Simulated Annealing...")
    sharpe, rendimiento, riesgo, pesos = get_portafolio_sa()

    reporte = construir_reporte(precios, divs, sharpe, rendimiento, riesgo, pesos)
    print("\n" + "="*55)
    print(reporte)

    # Guardar en archivo para uso externo
    with open("/app/state/01ea7918-f31e-4448-8b44-6a2ebf1e9da6/work/SA_TAFE/ultimo_reporte.txt", "w") as f:
        f.write(reporte)
    print("\n[OK] Reporte guardado en ultimo_reporte.txt")
