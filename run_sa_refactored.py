import numpy as np
import pandas as pd
import sa_tafe_metrics as metrics
import json

def objective_function(weights, tickers, ratios_df, profile):
    total_score = 0
    for i, ticker in enumerate(tickers):
        if weights[i] > 0.01:
            fin = metrics.get_financial_score(ticker, ratios_df, profile)
            if not fin['missing_data']: total_score += weights[i] * fin['score']
    return -total_score

def run_sa_optimized(tickers, ratios_path, profile='Balanceado', iterations=500):
    ratios_df = pd.read_csv(ratios_path)
    n = len(tickers)
    current_weights = np.ones(n) / n
    current_score = objective_function(current_weights, tickers, ratios_df, profile)
    best_weights, best_score = current_weights.copy(), current_score
    T = 1.0
    for i in range(iterations):
        new_weights = np.clip(current_weights + np.random.normal(0, 0.05, n), 0, 1)
        new_weights /= new_weights.sum()
        new_score = objective_function(new_weights, tickers, ratios_df, profile)
        if new_score < current_score or np.random.rand() < np.exp((current_score - new_score) / T):
            current_weights, current_score = new_weights, new_score
            if current_score < best_score: best_score, best_weights = current_score, current_weights
        T *= 0.99
    
    report = []
    for i, ticker in enumerate(tickers):
        if best_weights[i] > 0.01:
            fin = metrics.get_financial_score(ticker, ratios_df, profile)
            report.append({
                "ticker": ticker, "peso": f"{round(best_weights[i]*100, 1)}%", 
                "yield": f"{fin.get('yield',0)}%", "alerta": fin.get('alerta'),
                "explicacion": f"{ticker}: {round(best_weights[i]*100,1)}% — yield {fin.get('yield',0)}%, {'Datos No Disp.' if fin['missing_data'] else 'Analizado'}"
            })
    return report

if __name__ == "__main__":
    import os
    if os.path.exists('plantilla_financiera_ratios.csv'):
        print(json.dumps(run_sa_optimized(['FMTY14','DANHOS13','FUNO11'], 'plantilla_financiera_ratios.csv'), indent=2))
