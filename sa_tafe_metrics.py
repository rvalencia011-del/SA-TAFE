import pandas as pd
import numpy as np

def calculate_dividend_stability(dividend_history):
    if len(dividend_history) < 4: return 0.5
    mean_div = np.mean(dividend_history)
    if mean_div == 0: return 0
    stability = 1 - (np.std(dividend_history) / mean_div)
    return max(0, stability)

def get_financial_score(ticker, ratios_df, profile='Balanceado'):
    profiles = {
        'Conservador': {'w1': 0.3, 'w2': 0.4, 'w4': 0.3},
        'Balanceado':  {'w1': 0.4, 'w2': 0.3, 'w4': 0.3},
        'Crecimiento': {'w1': 0.5, 'w2': 0.2, 'w4': 0.3}
    }
    p = profiles.get(profile, profiles['Balanceado'])
    try:
        row = ratios_df[ratios_df['ticker'] == ticker].iloc[0]
        yield_f = float(row.get('yield_forward', 0))
        ltv = float(row.get('ltv', 0))
        payout = float(row.get('payout', 0))
        stability = float(row.get('stability_score', 0.7))
        penalty = 0
        if ltv > 0.45: penalty += 0.2
        if payout > 0.90: penalty += 0.2
        score = (p['w1'] * yield_f) + (p['w2'] * stability) - (p['w4'] * penalty)
        return {'score': score, 'yield': yield_f, 'stability': stability, 'ltv': ltv, 'payout': payout, 'alerta': "Riesgo Financiero" if penalty > 0 else None, 'missing_data': False}
    except:
        return {'score': 0, 'missing_data': True, 'alerta': "Dato No Disponible"}
