import json, os
from datetime import datetime
def actualizar():
    try:
        with open("IA_FINAL.json", 'r') as f: ia_data = json.load(f)
    except: ia_data = []
    master = {item['ticker']: {"p": item.get('price'), "y": item.get('yield'), "s": item.get('score', 50), "a": item.get('action', 'MANTENER'), "t": datetime.now().isoformat()} for item in ia_data}
    with open("DATABASE_MASTER.json", "w") as f: json.dump(master, f, indent=2)
if __name__ == "__main__": actualizar()
