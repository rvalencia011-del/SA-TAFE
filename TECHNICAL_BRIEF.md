# TECHNICAL_BRIEF: SA-TAFE Monitoring System (v2.0)
**Fecha de actualización:** 2026-07-22
**Estado:** Producción / Escalabilidad habilitada

## 1. Visión General
El sistema SA-TAFE ha evolucionado de un script de análisis técnico a una plataforma de datos masivos (Big Data) para FIBRAs en México. La versión 2.0 introduce la estandarización de estados financieros y la automatización de la ingesta de datos fundamentales desde reportes trimestrales (PDF).

## 2. Arquitectura de Datos (Nueva Estructura)
El repositorio ahora se organiza bajo el concepto de **"Plantillas Maestras"** para garantizar que el análisis sea comparable entre todas las emisoras.

### 2.1. Base de Datos Maestra (Única Fuente de Verdad)
- **`DATABASE_MASTER_SA_TAFE.json`**: Consolida tres capas de datos:
  - **Capa Técnica**: Precios en tiempo real y Yields (vía Yahoo Finance).
  - **Capa Histórica**: Registro completo de dividendos históricos de cada FIBRA.
  - **Capa Fundamental**: Ratios extraídos de reportes trimestrales (1T 2026).

### 2.2. Plantillas Financieras Estandarizadas (Input)
Se han creado plantillas basadas en modelos contables para que cualquier nueva FIBRA sea procesada bajo el mismo estándar:
- `plantilla_financiera_balance.csv`
- `plantilla_financiera_cashflow.csv`
- `plantilla_financiera_income.csv`
- `plantilla_financiera_ratios.csv`

## 3. Nuevas Funcionalidades Implementadas
1. **Extractor Profundo (OCR/Text Analysis)**: Capacidad de leer reportes trimestrales en PDF para identificar LTV, Ocupación y GLA (Metros cuadrados).
2. **Motor de Historial de Dividendos**: Descarga y almacenamiento automático de todos los pagos históricos para análisis de consistencia de flujo.
3. **Normalización de Tickers**: Sistema inteligente que vincula archivos PDF y CSV con los tickers oficiales de la BMV (ej: "Mty" -> "FMTY14").

## 4. Guía para el Desarrollador (Frontend/Web)
Para alimentar la plataforma web, el desarrollador **solo debe consumir** el archivo `DATABASE_MASTER_SA_TAFE.json`.
- **Campos Disponibles**: `precio`, `yield_anual`, `historial_completo`, `fundamental: {LTV, Ocupacion, Propiedades}`.
- **Formato**: JSON estándar compatible con cualquier framework (React, Vue, etc.).

## 5. Próximos Pasos (Roadmap)
- Integración de **Alertas Cualitativas**: Notificar cambios de ocupación > 5% entre trimestres.
- **Score de Salud Dinámico**: El algoritmo SA-TAFE penalizará automáticamente a las FIBRAs que no cumplan con el llenado de las plantillas financieras.
