# SA-TAFE AI SKILL DEFINITION

## Propósito
Esta habilidad permite analizar FIBRAs (REITs Mexicanos) usando el algoritmo SA-TAFE, optimizando por **Ingresos y Estabilidad** en lugar de solo precio.

## Archivos de Datos (Fuentes de Verdad)
- **IA_FINAL.json**: Resultados del último análisis de inteligencia (Score, Acción, Yield).
- **DATASET_ANALISIS_PROFUNDO.json**: Métricas fundamentales (LVT, NAV, Ocupación).
- **plantilla_financiera_ratios.csv**: Datos base para cálculos.

## Cómo usar esta habilidad (Instrucciones para la IA)
1. **Consulta de Ratios**: Para dar una recomendación, lee primero `IA_FINAL.json`.
2. **Lógica de Decisión**:
   - Score > 80: Compra Fuerte.
   - Score < 40: Venta/Riesgo.
   - Priorizar FIBRAs con LVT < 35% y Payout < 90%.
3. **Optimización**: Usa `run_sa_refactored.py` para recalcular pesos del portafolio según el perfil (Conservador, Balanceado, Crecimiento).

## Endpoints de Datos en Tiempo Real (RAW)
- https://raw.githubusercontent.com/rvalencia011-del/SA-TAFE/main/IA_FINAL.json
- https://raw.githubusercontent.com/rvalencia011-del/SA-TAFE/main/DATASET_ANALISIS_PROFUNDO.json
