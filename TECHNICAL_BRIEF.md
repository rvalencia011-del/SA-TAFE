# Technical Brief — Sistema de Monitoreo de FIBRAs
**Para el desarrollador de la app web**
**Fecha:** 22/07/2026

---

## ¿Qué es esto?

Sistema automatizado que cada tarde al cierre de la BMV genera un reporte de las 15 FIBRAs mexicanas principales con el portafolio óptimo calculado por el algoritmo **SA-TAFE** (Simulated Annealing).

---

## Repositorio

**GitHub:** https://github.com/rvalencia011-del/SA-TAFE (privado)
Solicitar acceso al owner: `rvalencia011-del`

---

## Cómo funciona el backend

### Flujo diario (automático, L-V a las 15:05 CST)
```
1. Descarga precios de cierre → Yahoo Finance API
2. Descarga dividendos reales → Bolsapp (BMV)
3. Corre algoritmo SA-TAFE   → calcula portafolio óptimo
4. Genera reporte             → ultimo_reporte.txt
```

### Archivos clave
| Archivo | Descripción |
|---|---|
| `saipo_mod_2abr26___public.py` | Algoritmo SA-TAFE principal |
| `run_sa.py` | Ejecuta la optimización, retorna pesos |
| `reporte_diario.py` | Orquesta todo el flujo |
| `bolsapp_ids.json` | IDs internos de Bolsapp para las 15 FIBRAs |
| `FIBRA_EFT_MX_20_26_Wk_full.csv` | Histórico de precios 2020–2026 |

---

## Output del sistema

El reporte generado tiene esta estructura:

```
📊 FIBRA RATIOS — DIVIDEND YIELD FORWARD
📅 Miércoles 22/07/2026 | Cierre BMV

Ticker        Precio  Div Anual   Yield  Payout
──────────────────────────────────────────────────
FHIPO14      $ 14.14      $1.42  10.04%    381%
FIHO12       $  7.40      $0.61   8.24%    121%
FUNO11       $ 30.45      $2.47   8.11%     47%
...

🤖 PORTAFOLIO ÓPTIMO SA-TAFE
Sharpe: 2.1536 | Rend: 27.56% | Riesgo: 10.01%

  FNOVA17        50.91%
  FHIPO14        20.0%
  FIBRAMQ12      10.91%
  FMTY14         10.91%
  FIBRAPL14      7.27%
```

---

## Lo que necesita la app web

### Vista principal — Dashboard
- Tabla de las 15 FIBRAs con: Ticker, Precio, Div Anual, Yield, Payout
- Sección "Portafolio Óptimo": Sharpe, Rendimiento, Riesgo + tabla de pesos
- Fecha y hora del último reporte
- Indicador: fuente de datos (Yahoo Finance / Bolsapp)

### Opciones de integración (elige una)

**Opción A — Leer el archivo generado**
El script ya guarda `ultimo_reporte.txt` en el servidor.
La app solo lee ese archivo y lo renderiza.
Simple, sin cambios al backend.

**Opción B — API JSON (recomendada)**
Modificar `reporte_diario.py` para que además guarde `ultimo_reporte.json`:
```json
{
  "fecha": "2026-07-22",
  "hora": "15:05",
  "fibras": [
    {
      "ticker": "FHIPO14",
      "nombre": "FIBRA Hipotecaria",
      "precio": 14.14,
      "div_anual": 1.42,
      "yield": 10.04,
      "payout": 381
    }
  ],
  "portafolio_optimo": {
    "sharpe": 2.1536,
    "rendimiento": 27.56,
    "riesgo": 10.01,
    "pesos": {
      "FNOVA17": 50.91,
      "FHIPO14": 20.0,
      "FIBRAMQ12": 10.91,
      "FMTY14": 10.91,
      "FIBRAPL14": 7.27
    }
  }
}
```

---

## Stack actual del backend
- **Lenguaje:** Python 3
- **Librerías:** yfinance, pandas, numpy, scipy, playwright
- **Scheduler:** Cron job (L-V 15:05 CST)
- **Datos:** Yahoo Finance (precios) + Bolsapp/BMV (dividendos)

---

## Notas importantes
- Las FIBRAs **FHIPO, FNOVA, FIBRATC y FCFE** no están en Bolsapp — usan Yahoo como fallback
- El algoritmo SA-TAFE está basado en el paper TAFE v5.4 (incluido en repo como `TAFE_v5_4_EN.R`)
- ⚠️ El reporte **no es recomendación de inversión**

---
*Documento generado por Zapia | github.com/rvalencia011-del/SA-TAFE*
