# 📊 ScalpingGrid Expert Advisor (MQL5)

**ScalpingGrid** es un asesor experto avanzado para MetaTrader 5 que implementa una estrategia de **grilla equidistante infinita**. Está diseñado para traders que buscan una gestión algorítmica de niveles de precio, integrando un **Filtro de Volatilidad ATR** y un **Módulo de Mitigación de Riesgo Dinámico** que adapta los parámetros de la operativa según el estado de la equidad.

---

## 🚀 Características Principales

*   **Grilla Flexible**: Permite elegir entre órdenes **Limit** (para estrategias de reversión) o **Stop** (para seguimiento de tendencia).
*   **Filtro ATR**: Evita operar en mercados laterales sin movimiento o con volatilidad excesiva, eliminando automáticamente las órdenes pendientes si el ATR sale del rango definido.
*   **Hedging Imbalance Guard**: Monitorea el diferencial entre posiciones de compra y venta para evitar una exposición direccional peligrosa que supere los límites establecidos.
*   **Módulo de Mitigación de Riesgo**: 
    *   **Escalado por Drawdown**: Si la cuenta sufre una caída mayor al 50%, el EA incrementa la distancia de la grilla y los objetivos de beneficio para reducir el riesgo.
    *   **Protección de Minorías**: En situaciones de desequilibrio crítico, el EA protege el lado con menos exposición eliminando su Take Profit para permitir una cobertura más eficiente.
*   **Trailing Stop Inteligente**: Asegura beneficios de forma dinámica, bloqueándose automáticamente si el módulo de protección está activo para evitar cierres prematuros en coberturas.

---

## 🛠 Parámetros de Configuración

### Configuración de la Grilla
| Parámetro | Descripción |
| :--- | :--- |
| **Distancia** | Espacio en puntos entre cada nivel de la grilla. |
| **Tipo de Orden** | Selección entre `Limit` o `Stop`. |
| **Volumen** | Lotes por cada operación individual. |
| **Niveles de Grilla** | Cantidad de niveles a mantener activos por lado. |

### Gestión de Riesgo y Salida
| Parámetro | Descripción |
| :--- | :--- |
| **TP / SL** | Take Profit y Stop Loss (0 desactiva el SL para modo cobertura puro). |
| **Max Imbalance** | Máxima diferencia permitida entre el número de Compras y Ventas. |
| **Trailing Stop** | Distancia para el seguimiento de beneficios. |

### Filtro de Volatilidad
| Parámetro | Descripción |
| :--- | :--- |
| **ATR Period** | Periodo de cálculo del indicador Average True Range. |
| **Min/Max ATR** | Rango de volatilidad en el que se permite la colocación de órdenes. |

---

## 📈 Lógica de Mitigación Dinámica

El EA incluye una capa de inteligencia financiera para proteger el capital en escenarios adversos:

1.  **Ajuste por Drawdown (DD > 50%)**:
    El sistema aplica una fórmula de escalado para las nuevas órdenes:
    $$M = \frac{1}{1 - StepDD}$$
    Esto aumenta la distancia entre niveles y los objetivos de precio, haciendo que el bot sea más "paciente" mientras la cuenta se recupera.

2.  **Gestión de Desequilibrio**:
    Si el flotante negativo supera la equidad y el desequilibrio de órdenes es mayor al permitido, el EA entra en modo de defensa. Elimina los TPs del lado minoritario para que esas posiciones funcionen como un "escudo" de cobertura total.

---

## 📦 Instalación

1.  Descarga el archivo `ScalpingGrid.mq5`.
2.  En MetaTrader 5, ve a **Archivo > Abrir carpeta de datos**.
3.  Copia el archivo en la ruta `MQL5/Experts/`.
4.  Refresca la lista de asesores expertos en el terminal.
5.  Arrastra el EA al gráfico del símbolo deseado y asegúrate de permitir el **Algo Trading**.

---

> **⚠️ Descargo de Responsabilidad**: El trading con sistemas de grilla y cobertura implica un riesgo significativo de pérdida de capital. Se recomienda probar este EA en cuentas de demostración antes de pasar a un entorno real. El autor no se hace responsable de las decisiones financieras tomadas con este software.
