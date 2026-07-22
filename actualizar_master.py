import json, os, yfinance as yf
from datetime import datetime

def actualizar():
    try:
        with open("IA_FINAL.json", 'r') as f: ia_data = json.load(f)
    except: ia_data = []
    
    tickers = [f"{i['ticker']}.MX" for i in ia_data]
    data = yf.download(tickers, period="1d")['Close'].iloc[-1].to_dict() if tickers else {}
    
    master = {}
    for item in ia_data:
        t = item['ticker']
        p = round(float(data.get(f"{t}.MX", 0)), 2)
        master[t] = {
            "precio": p,
            "yield": item.get('yield'),
            "score": item.get('score'),
            "accion": item.get('action'),
            "t": datetime.now().isoformat()
        }
    with open("DATABASE_MASTER_SA_TAFE.json", "w") as f: json.dump(master, f, indent=2)

if __name__ == "__main__": actualizar()
