import numpy as np
import pandas as pd
import random
import math
from timeit import default_timer
from collections import Counter
import yfinance as yf
from datetime import datetime, timedelta

# --- Descarga de datos actualizados desde Yahoo Finance ---
fibras = ['FIBRATC14.MX','FCFE18.MX','FHIPO14.MX','TERRA13.MX','FUNO11.MX',
          'FSHOP13.MX','FPLUS16.MX','FMTY14.MX','FINN13.MX','FIHO12.MX',
          'FIBRAPL14.MX','FIBRAMQ12.MX','FIBRAHD15.MX','DANHOS13.MX','FNOVA17.MX']

fecha_inicio = '2020-01-01'
fecha_fin = datetime.today().strftime('%Y-%m-%d')
print(f"Descargando datos de Yahoo Finance ({fecha_inicio} → {fecha_fin})...")

raw = yf.download(fibras, start=fecha_inicio, end=fecha_fin,
                  interval='1wk', auto_adjust=True, progress=False)

# Extraer precios de cierre
if isinstance(raw.columns, pd.MultiIndex):
    df = raw['Close']
else:
    df = raw

period = 52

# Limpiar datos
df = df.dropna(axis=1, thresh=int(len(df)*0.7))  # quitar columnas con >30% nulos
df = df.interpolate(limit_direction='both', method='linear')
df = df.ffill().bfill()
df_returns = df.pct_change(periods=1).dropna()
assets = df.columns
print(f"FIBRAs con datos validos: {list(assets)}")
print(f"Datos descargados: {len(df)} semanas\n")

rf = 0.06
marr = 0.00 / period

def Ves(assets, returns):
    ves = []
    for serie in assets:
        x, rangos = np.histogram(returns[serie], bins=10)
        y = [(rangos[i+1]+rangos[i])/2 for i in range(len(rangos)-1)]
        p = x / len(df_returns)
        ve = sum(p * np.array(y))
        ves.append(ve)
    return ves

ves = np.array(Ves(assets, df_returns))
ves = ((1 + ves)**period) - 1
ves_data = pd.DataFrame(ves, index=assets, columns=['VE'])

assets_drop = list(ves_data.index[(ves_data['VE'] < marr)])
ves_final = ves_data[(ves_data['VE'] >= marr)]
ves = np.array(ves_final['VE'])
assets = ves_final.index

if assets_drop:
    df = df.drop(assets_drop, axis=1)
    df_returns = df_returns.drop(assets_drop, axis=1)

C = np.cov(df_returns.transpose())
desv_std = np.array(np.std(df_returns)) * period**(1/2)

def normalize(array):
    s = sum(array)
    return [i/s for i in array]

def weights_random(n):
    w = [random.randint(0, 100) for _ in range(n)]
    return np.array(normalize(w))

def portfolio_risk(w, C):
    w = np.asarray(w).flatten()
    variance = np.dot(w, np.dot(C, w))
    return np.sqrt(np.maximum(0, variance)).item() * period**(1/2)

def return_port(ves, w):
    return np.dot(np.asarray(ves).flatten(), np.asarray(w).flatten()).item()

def Sharpe_port(ret, rf, risk):
    return (ret - rf) / risk

def sigma(w, C):
    return np.dot(w, np.dot(C, w.T))

def Sharpe(ret, rf, sig):
    return (ret - rf) / (sig**(1/2) * period**(1/2))

def corr_prom(w, desv_std, p_risk):
    weighted_var_individual = np.sum((w**2) * (desv_std**2))
    cross_term = (p_risk**2) - weighted_var_individual
    sum_w_std = np.sum(w * desv_std)
    denominator = (sum_w_std**2) - weighted_var_individual
    if denominator == 0:
        return 0
    return cross_term / denominator

def RegularPerturbation(w, q):
    w_new = w.copy()
    idx1, idx2 = random.sample(range(len(w_new)), 2)
    transfer = min(q, w_new[idx1])
    w_new[idx1] -= transfer
    w_new[idx2] += transfer
    return w_new / np.sum(w_new)

T0 = 0.944879
Tf = 0.000074
alfa = 0.93
Lmax = len(assets) * 3.51
L0 = 300
n_iters = (math.log(Tf) - math.log(T0)) / math.log(alfa)
Beta = math.e**((math.log(Lmax) - math.log(L0)) / n_iters)
parameters = [T0, Tf, alfa, L0, Beta]

def SAIPO(parameters):
    T, Tf, alfa, L, Beta = parameters
    w_current = weights_random(len(assets))
    risk_portfolio = portfolio_risk(w_current, C)
    return_portfolio = return_port(ves, w_current)
    Sharpe_current = Sharpe_port(return_portfolio, rf, risk_portfolio)
    s = Sharpe_current
    Assets_best = w_current.copy()

    while T >= Tf:
        k = 0
        while k < L:
            q = 1 / (len(w_current) * 5)
            w_new = RegularPerturbation(w_current, q)
            return_port_new = return_port(ves, w_new)
            risk_port_new = portfolio_risk(w_new, C)
            Sharpe_new = Sharpe_port(return_port_new, rf, risk_port_new)
            Delta = Sharpe_new - Sharpe_current
            rand = random.random()
            boltzman = math.e**(Delta / T)
            if Delta > 0:
                Sharpe_current = Sharpe_new
                w_current = w_new
                if Sharpe_current > s:
                    s = Sharpe_current
                    Assets_best = w_current.copy()
            elif rand < boltzman:
                Sharpe_current = Sharpe_new
                w_current = w_new
            k += 1
        L = Beta * L
        T = T * alfa

    portfolio_final = pd.DataFrame(
        [round(i, 4) for i in Assets_best],
        index=assets, columns=['Weight']
    ).sort_values(by='Weight', ascending=False)
    risk_final = sigma(Assets_best, C)
    risk_port_final = portfolio_risk(Assets_best, C)
    expected_return = return_port(ves, Assets_best)
    correlacion = corr_prom(Assets_best, desv_std, risk_port_final)
    SR = Sharpe(expected_return, rf, risk_final)
    return s, expected_return, risk_port_final, correlacion, Assets_best, risk_final, SR, portfolio_final

print(f"Iniciando optimizacion SA con datos reales ({fecha_inicio} → {fecha_fin})...\n")
random.seed(42)
np.random.seed(42)

n_experiments = 10
sharpes, rendimientos, riesgos, portfolios = [], [], [], []

for i in range(n_experiments):
    inicio = default_timer()
    res = SAIPO(parameters)
    fin = default_timer()
    sharpes.append(round(res[0], 4))
    rendimientos.append(round(res[1], 4))
    riesgos.append(round(res[2], 4))
    portfolios.append(res[7])
    print(f"Experimento {i+1}/10 | Sharpe={round(res[0],4)} | Rendimiento={round(res[1]*100,2)}% | Riesgo={round(res[2]*100,2)}% | Tiempo={round(fin-inicio,1)}s")

best_idx = sharpes.index(max(sharpes))
best_portfolio = portfolios[best_idx]
best_sharpe = sharpes[best_idx]
best_return = rendimientos[best_idx]
best_risk = riesgos[best_idx]

print(f"\n{'='*50}")
print(f"MEJOR PORTAFOLIO (experimento {best_idx+1})")
print(f"Sharpe:      {best_sharpe}")
print(f"Rendimiento: {round(best_return*100, 2)}%")
print(f"Riesgo:      {round(best_risk*100, 2)}%")
print(f"\nAsignacion de activos (peso > 1%):")
top = best_portfolio[best_portfolio['Weight'] > 0.01]
for asset, row in top.iterrows():
    print(f"  {asset:35s} {round(row['Weight']*100, 2)}%")

all_assets_used = []
for p in portfolios:
    active = p[p['Weight'] > 0.005].index.tolist()
    all_assets_used.extend(active)

freq = Counter(all_assets_used)
print(f"\nActivos mas frecuentes (10 experimentos):")
for asset, count in freq.most_common(10):
    print(f"  {asset:35s} {count}/10 experimentos")
