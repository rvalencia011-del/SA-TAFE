# -*- coding: utf-8 -*-
"""
Created on Thu Mar 12 19:47:54 2026

@author: pepep
"""
import pandas as pd
import numpy as np

def imputar_con_proxy(df, proxy_col='NAFTRACISHRS.MX'):
    """
    Rellena huecos de datos usando la relación de rendimiento con un índice (Proxy).
    Ideal para mantener la estructura de correlación en activos con historial corto.
    """
    df_imputado = df.copy()
    
    if proxy_col not in df_imputado.columns:
        print(f"Advertencia: No se encontró la columna {proxy_col}. Se usará ffill/bfill simple.")
        return df_imputado.ffill().bfill()

    proxy = df_imputado[proxy_col]
    
    for col in df_imputado.columns:
        if col == proxy_col:
            continue
            
        # 1. Rellena huecos internos pequeños con interpolación lineal por tiempo
        df_imputado[col] = df_imputado[col].interpolate(method='time', limit=4, limit_area='inside')
        
        # 2. Rellena por Proxy (Extrapolación retrospectiva)
        first_valid_idx = df_imputado[col].first_valid_index()
        
        if first_valid_idx is not None:
            pos = df_imputado.index.get_loc(first_valid_idx)
            
            # Si hay espacios vacíos antes del primer dato real (Inicio de la serie)
            if pos > 0:
                for i in range(pos - 1, -1, -1):
                    # Factor de cambio del mercado: Proxy_{t} / Proxy_{t+1}
                    # Vamos hacia atrás, calculando el precio estimado anterior
                    ratio = proxy.iloc[i] / proxy.iloc[i+1]
                    
                    valor_estimado = df_imputado.iloc[i+1, df_imputado.columns.get_loc(col)] * ratio
                    df_imputado.iloc[i, df_imputado.columns.get_loc(col)] = valor_estimado

    # 3. Rellenar huecos al final (Forward fill para datos muy recientes)
    df_imputado = df_imputado.ffill()
    
    return df_imputado

# --- FLUJO DE TRABAJO ---

# 1. Cargar tus datos originales
# 'Date'  como índice de tiempo
df_raw = pd.read_csv('C:/DOCTORADO/ART 2025/ETFS/ETF_FIB_20_26/FIBRA_EFT_MX_20_26_Dy_RAW.csv', index_col=0, parse_dates=True)

# 2. Aplicar la limpieza avanzada
df_clean = imputar_con_proxy(df_raw, proxy_col='NAFTRACISHRS.MX')

# 3. Verificación de resultados
print("Dimensiones originales:", df_raw.shape)
print("NaNs restantes por columna:\n", df_clean.isna().sum())

# 4. Exportar para para el algoritmo SAIPO
df_clean.to_csv('C:/DOCTORADO/ART 2025/ETFS/ETF_FIB_20_26/FIBRA_EFT_MX_20_26_Dy_full_PROXY.csv')