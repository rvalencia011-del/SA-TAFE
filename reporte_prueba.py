"""
reporte_prueba.py — versión sin Playwright, solo Yahoo Finance
Para prueba inmediata. El cron diario usará Bolsapp con Playwright.
"""

import json, subprocess, sys
from datetime import datetime

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

import yfinance as yf

def get_datos():
    datos = {}
    for ticker, nombre in FIBRAS_YAHOO.items():
        try:
            t = yf.Ticker(ticker)
            info = t.info
            precio = info.get('currentPrice') or info.get('regularMarketPrice') or info.get('previousClose')
            if not precio:
                continue
            div_rate = info.get('dividendRate') or 0
            max52    = info.get('fiftyTwoWeekHigh')
            payout   = info.get('payoutRatio')
            ticker_b = ticker.replace('.MX','')
            datos[ticker_b] = {
                'nombre':  nombre,
                'precio':  precio,
                'div':     div_rate,
                'max52':   max52,
                'payout':  payout,
            }
            print(f"  {ticker_b}: ${precio:.2f}  div=${div_rate:.2f}")
        except Exception as e:
            print(f"  [!] {ticker}: {e}")
    return datos

def get_portafolio_sa():
    try:
        result = subprocess.run(
            ["python3", "/app/state/01ea7918-f31e-4448-8b44-6a2ebf1e9da6/work/SA_TAFE/run_sa.py"],
            capture_output=True, text=True, timeout=120
        )
        out = result.stdout
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
            if '%' in line and '.MX' in line:
                parts = line.strip().split()
                if len(parts) == 2:
                    ticker = parts[0].replace('.MX','')
                    pesos[ticker] = parts[1]
        return sharpe, rendimiento, riesgo, pesos
    except Exception as e:
        print(f"[SA] Error: {e}")
        return None, None, None, {}

def construir_reporte(datos, sharpe, rendimiento, riesgo, pesos):
    hoy = datetime.today().strftime("%d/%m/%Y")
    dias = ["Lunes","Martes","Miércoles","Jueves","Viernes","Sábado","Domingo"]
    dia_semana = dias[datetime.today().weekday()]

    # Ordenar por yield descendente
    ordenados = sorted(datos.items(), key=lambda x: -(
        (x[1]['div'] / x[1]['precio'] * 100) if (x[1]['precio'] and x[1]['div']) else 0
    ))

    lineas = []
    lineas.append(f"📊 *FIBRA RATIOS — DIVIDEND YIELD FORWARD*")
    lineas.append(f"📅 {dia_semana} {hoy} | Cierre BMV")
    lineas.append(f"")
    lineas.append(f"{'Ticker':<12} {'Precio':>7} {'Div Anual':>10} {'Yield':>7} {'Payout':>7}")
    lineas.append("─" * 50)

    for ticker_b, d in ordenados:
        precio   = d['precio']
        div      = d['div']
        max52    = d['max52']
        payout   = d['payout']

        yield_str  = f"{div/precio*100:.2f}%" if div else " N/D"
        div_str    = f"${div:.2f}" if div else "   N/D"
        payout_str = f"{round(payout*100)}%" if payout else " N/D"

        lineas.append(f"{ticker_b:<12} ${precio:>6.2f} {div_str:>10} {yield_str:>7} {payout_str:>7}")

    lineas.append("")
    lineas.append("🤖 *PORTAFOLIO ÓPTIMO SA-TAFE*")
    if sharpe:
        lineas.append(f"Sharpe: {sharpe:.4f} | Rend: {rendimiento} | Riesgo: {riesgo}")
        lineas.append("")
        for ticker, peso in sorted(pesos.items(), key=lambda x: -float(x[1].replace('%',''))):
            lineas.append(f"  {ticker:<14} {peso}")
    else:
        lineas.append("  (Sin datos SA hoy)")
    lineas.append("")
    lineas.append("─" * 50)
    lineas.append("Fuente: Yahoo Finance | Dividendos: Bolsapp (BMV)")
    lineas.append("⚠️ No es recomendación de inversión.")

    return "\n".join(lineas)

if __name__ == "__main__":
    print("Descargando precios y dividendos...")
    datos = get_datos()
    print("\nCorriendo Simulated Annealing...")
    sharpe, rendimiento, riesgo, pesos = get_portafolio_sa()
    reporte = construir_reporte(datos, sharpe, rendimiento, riesgo, pesos)

    output_path = "/app/state/01ea7918-f31e-4448-8b44-6a2ebf1e9da6/work/SA_TAFE/ultimo_reporte.txt"
    with open(output_path, "w") as f:
        f.write(reporte)

    print("\n" + "="*55)
    print(reporte)
    print(f"\n[OK] Guardado en {output_path}")
