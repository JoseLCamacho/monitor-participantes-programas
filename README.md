##  Objetivo del Código

Este script de R automatiza la **consolidación, limpieza y deduplicación** de bases de datos de participantes provenientes de múltiples fuentes (archivos Excel en Google Drive). 

Su propósito principal es generar un conteo fiable de **participantes únicos** y su distribución por programas, implementando un flujo de trabajo **"humano en el bucle" (human-in-the-loop)** para validar inconsistencias en los identificadores antes del conteo final.

---

##  ¿Por qué se usa este enfoque? (Racional)

En proyectos sociales y de impacto, las bases de datos suelen presentar "ruido" que infla artificialmente las métricas o genera reportes erróneos. Este código resuelve cuatro problemas críticos:

1. **Evita el sobreconteo por errores de digitación:** 
   Usa *fuzzy matching* (distancia de Levenshtein) para detectar IDs similares (ej. `12345678` vs `12345679`) que un `distinct()` tradicional pasaría por alto, agrupándolos para que un analista decida cuál es el correcto.

2. **Previene fusiones accidentales de personas distintas:** 
   A diferencia de scripts que unen datos solo por "Nombre" (riesgoso por homónimos), las funciones de corrección cruzan `Nombre` + `Fuente_Datos`, garantizando que dos "Juan Pérez" de diferentes bases no se fusionen erróneamente.

3. **Optimiza el tiempo de limpieza de datos:** 
   En lugar de revisar manualmente miles de filas, el algoritmo filtra y exporta solo los casos sospechosos (IDs compartidos, errores de tipeo, IDs inválidos) a un Excel. El analista solo interviene en los casos dudosos, y el script aplica los cambios de forma vectorizada (en milisegundos).

4. **Auditoría y trazabilidad de la calidad del dato:** 
   No solo entrega un número final, sino que clasifica a los participantes en tres estados: **Confirmados**, **En Revisión** y **Pendientes de Verificación**, permitiendo a la organización saber exactamente qué tan confiable es su métrica de impacto.

---

## ⚙️ Flujo de Trabajo (Cómo usarlo)

1. **Ejecutar Partes 1 a 3:** El script descarga los datos, los une y genera dos archivos en la carpeta `output/`:
   - `alertas_ids_para_verificacion.xlsx` (Para que el analista decida si son errores de digitación o personas distintas).
   - `registros_sin_id_para_verificacion.xlsx` (Para que el equipo de campo complete datos faltantes).
2. **Revisión Humana:** Un usuario completa las columnas de decisión en los Excel generados.
3. **Aplicar Correcciones:** Ejecutar las funciones `aplicar_decisiones()` y `actualizar_ids_faltantes()` en la consola de R.
4. **Ejecutar Parte 4:** Descomentar la línea `bd_final <- bd_corregida` y ejecutar para generar los reportes finales de conteo y calidad.
