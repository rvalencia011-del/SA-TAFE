import pdfplumber
import os
import json
import re

PDF_DIR = '/app/state/01ea7918-f31e-4448-8b44-6a2ebf1e9da6/work/SA_TAFE/reportes_pdf'
OUTPUT_DATA = '/app/state/01ea7918-f31e-4448-8b44-6a2ebf1e9da6/work/SA_TAFE/DATOS_REALES_1T2026.json'

def extract_from_pdf(file_path):
    data = {
        "LTV": None,
        "Ocupacion": None,
        "Metros_Cuadrados": None,
        "Propiedades": None
    }
    try:
        with pdfplumber.open(file_path) as pdf:
            text = ""
            # Leemos las primeras 10 páginas que suelen tener los resúmenes ejecutivos
            for page in pdf.pages[:10]:
                text += page.extract_text() or ""
            
            # Buscar LTV (Loan to Value) o Apalancamiento
            ltv_match = re.search(r'(LTV|Apalancamiento|Loan to Value)[:\s]*(\d+\.?\d*)\s*%', text, re.IGNORECASE)
            if ltv_match:
                data["LTV"] = ltv_match.group(2) + "%"
            
            # Buscar Ocupación
            ocu_match = re.search(r'(Ocupación|Occupancy)[:\s]*(\d+\.?\d*)\s*%', text, re.IGNORECASE)
            if ocu_match:
                data["Ocupacion"] = ocu_match.group(2) + "%"
                
            # Buscar GLA / Metros Cuadrados (Area Bruta Rentable)
            gla_match = re.search(r'(GLA|ABR|Área Bruta Rentable)[:\s]*([\d,]+)\s*(m2|metros|sqft)', text, re.IGNORECASE)
            if gla_match:
                data["Metros_Cuadrados"] = gla_match.group(2)
                
            # Buscar Número de Propiedades
            prop_match = re.search(r'(\d+)\s*(propiedades|inmuebles|properties)', text, re.IGNORECASE)
            if prop_match:
                data["Propiedades"] = prop_match.group(1)
                
    except Exception as e:
        print(f"Error procesando {file_path}: {e}")
    return data

def main():
    results = {}
    archivos = [f for f in os.listdir(PDF_DIR) if f.endswith('.pdf')]
    print(f"Iniciando extracción de {len(archivos)} reportes...")
    
    for archivo in archivos:
        ticker = archivo.split('-')[-1].replace('.pdf', '').upper()
        # Normalización de tickers comunes
        if 'DANHOS' in ticker: ticker = 'DANHOS13'
        if 'MTY' in ticker: ticker = 'FMTY14'
        if 'FUNO' in ticker: ticker = 'FUNO11'
        if 'NOVA' in ticker: ticker = 'FNOVA17'
        if 'PROLOGIS' in ticker: ticker = 'FIBRAPL14'
        if 'MACQUARIE' in ticker: ticker = 'FIBRAMQ12'
        
        print(f"Analizando {ticker}...")
        results[ticker] = extract_from_pdf(os.path.join(PDF_DIR, archivo))
        results[ticker]["fuente"] = archivo
        results[ticker]["periodo"] = "1T2026"

    with open(OUTPUT_DATA, 'w', encoding='utf-8') as f:
        json.dump(results, f, indent=4, ensure_ascii=False)
    print(f"Extracción completada. Datos guardados en {OUTPUT_DATA}")

if __name__ == "__main__":
    main()
