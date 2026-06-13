################################################################################
# SISTEMA DE MONITOREO Y CONTEO DE PARTICIPANTES (VERSIÓN OPTIMIZADA)
################################################################################

# ==============================================================================
# PARTE 1: CONFIGURACIÓN Y CARGA DE DATOS
# ==============================================================================

# 1. LIMPIEZA: Elimina objetos previos y libera memoria para evitar conflictos
rm(list = ls())
gc()
cat("\n=== Entorno limpio ===\n")

# 2. LIBRERÍAS: Carga de paquetes necesarios para manipulación, conexión y fuzzy matching
# Nota: Si no tienes 'fuzzyjoin' o 'writexl', instálalos con: install.packages("fuzzyjoin", "writexl")
library(tidyverse)
library(googledrive)
library(readxl)
library(fuzzyjoin)   # Crucial para detectar errores de digitación de forma rápida
library(writexl)     # Para exportar a Excel sin depender de Java (openxlsx)

# 3. CONEXIÓN: Autentica tu cuenta de Google (abre navegador la primera vez)
drive_auth()

# 4. DESCARGA INTELIGENTE: Busca por nombre (no por ID) y descarga temporalmente
nombres_archivos <- c("nombre_archivo_1.xlsx", "nombre_archivo_2.xlsx", "nombre_archivo_3.xlsx")
rutas_temp <- character(length(nombres_archivos))

for (i in seq_along(nombres_archivos)) {
  cat("Buscando en Drive:", nombres_archivos[i], "...\n")
  # drive_find busca el archivo exacto y extrae su ID real automáticamente
  archivo_encontrado <- drive_find(pattern = paste0("^", nombres_archivos[i], "$"), type = "spreadsheet")
  
  if (nrow(archivo_encontrado) == 0) stop(paste("No se encontró:", nombres_archivos[i]))
  
  # Descarga en una carpeta temporal del sistema y guarda la ruta
  rutas_temp[i] <- drive_download(archivo_encontrado, path = tempfile(fileext = ".xlsx"), overwrite = TRUE)$local_path
}

# 5. LECTURA: Carga los archivos descargados a la memoria de R
bd1 <- read_excel(rutas_temp[1])
bd2 <- read_excel(rutas_temp[2])
bd3 <- read_excel(rutas_temp[3])


# ==============================================================================
# PARTE 2: UNIÓN DE BASES DE DATOS
# ==============================================================================

# UNE VERTICALMENTE las bases y agrega una columna 'Fuente_Datos' para saber de dónde vino cada registro
bd_unida <- bind_rows(
  bd1 %>% mutate(Fuente_Datos = "Base 1"),
  bd2 %>% mutate(Fuente_Datos = "Base 2"),
  bd3 %>% mutate(Fuente_Datos = "Base 3")
)

# ESTANDARIZACIÓN TEMPRANA: Convierte nombres a mayúsculas y quita espacios extra.
# Esto evita que "Juan Perez" y "JUAN PEREZ " se cuenten como personas distintas.
bd_unida <- bd_unida %>%
  mutate(
    Nombre = str_to_upper(str_trim(Nombre)),
    Identificacion = as.character(str_trim(Identificacion))
  )


# ==============================================================================
# PARTE 3: ANÁLISIS DE CALIDAD Y VERIFICACIÓN 
# ==============================================================================

# --- 3A. CONTEO INICIAL POR IDENTIFICACIÓN ---
conteo_id <- bd_unida %>%
  group_by(Identificacion) %>%
  summarise(
    Veces_Aparece = n(),
    Nombres_Asociados = paste(unique(Nombre), collapse = " | "),
    Programas = paste(unique(Fuente_Datos), collapse = ", "),
    Largo_ID = nchar(Identificacion), # Necesario para el filtro de velocidad en 3B
    .groups = "drop"
  ) %>%
  arrange(desc(Veces_Aparece))

cat("\nParticipantes únicos detectados:", nrow(conteo_id), "\n")


# --- 3B. DETECCIÓN RÁPIDA DE ERRORES DE DIGITACIÓN (FUZZY MATCHING) ---
cat("\n=== Buscando posibles errores de digitación en IDs... ===\n")

# Filtramos solo IDs que aparecen 1 vez para comparar contra todos
ids_unicos <- conteo_id %>% filter(Veces_Aparece == 1)

# stringdist_inner_join compara IDs. 
# TRUCO DE VELOCIDAD: El filtro 'abs(Largo_ID.x - Largo_ID.y) <= 2' evita comparar 
# millones de combinaciones inútiles, reduciendo el tiempo de horas a segundos.
errores_digitacion <- stringdist_inner_join(
  ids_unicos %>% select(Identificacion, Largo_ID, Nombres_Asociados),
  conteo_id %>% select(Identificacion, Largo_ID, Nombres_Asociados),
  by = "Identificacion", method = "lv", max_dist = 2
) %>%
  filter(
    abs(Largo_ID.x - Largo_ID.y) <= 2,          # Solo compara si la longitud es similar
    Identificacion.x != Identificacion.y        # Excluye la comparación de un ID consigo mismo
  ) %>%
  mutate(
    Distancia = stringdist(Identificacion.x, Identificacion.y, method = "lv"),
    Tipo_Alerta = "Posible_Error_Digitacion"
  ) %>%
  # Renombramos columnas para el reporte final y eliminamos duplicados (A-B y B-A)
  rename(ID_Sospechoso_1 = Identificacion.x, ID_Sospechoso_2 = Identificacion.y) %>%
  select(ID_Sospechoso_1, ID_Sospechoso_2, Nombres_Asociados = Nombres_Asociados.x, Distancia, Tipo_Alerta) %>%
  distinct()

# --- DETECCIÓN DE IDs COMPARTIDOS (Ej: Hermanos usando el mismo documento) ---
alertas_compartidos <- conteo_id %>%
  mutate(Cantidad_Nombres = lengths(strsplit(Nombres_Asociados, " \\| "))) %>%
  filter(Cantidad_Nombres > 1) %>%
  mutate(
    ID_Sospechoso_1 = Identificacion,
    ID_Sospechoso_2 = Identificacion,
    Distancia = 0,
    Tipo_Alerta = "IDs_Compartidos_Mismo_Documento"
  ) %>%
  select(ID_Sospechoso_1, ID_Sospechoso_2, Nombres_Asociados, Distancia, Tipo_Alerta)

# UNIFICAR ALERTAS Y EXPORTAR PARA REVISIÓN HUMANA
alertas_totales <- bind_rows(errores_digitacion, alertas_compartidos) %>%
  mutate(
    Decision_Analista = NA_character_, # El analista llenará esto en Excel
    ID_Correcto = NA_character_,
    Comentarios = NA_character_
  )

dir.create("output", showWarnings = FALSE)
write_xlsx(alertas_totales, "output/alertas_ids_para_verificacion.xlsx")
cat("✓ Archivo de alertas generado en: output/alertas_ids_para_verificacion.xlsx\n")


# --- 3C. DETECCIÓN DE IDs INVÁLIDOS O VACÍOS ---
bd_sin_id_valido <- bd_unida %>%
  filter(
    is.na(Identificacion) | Identificacion == "" | Identificacion == "0" | 
      Identificacion == "NA" | nchar(Identificacion) < 5 |
      !str_detect(Identificacion, "^[0-9]+$") # Fuerza que sean solo números
  )

write_xlsx(bd_sin_id_valido, "output/registros_sin_id_para_verificacion.xlsx")
cat("✓ Archivo de IDs inválidos generado en: output/registros_sin_id_para_verificacion.xlsx\n")


# ==============================================================================
# FUNCIONES DE CORRECCIÓN (EJECUTAR DESPUÉS DE REVISAR LOS EXCEL)
# ==============================================================================

# FUNCIÓN 1: Aplica las decisiones tomadas en el Excel de alertas
# Usa left_join + coalesce en lugar de un bucle 'for' para ser 100x más rápido.
aplicar_decisiones <- function(archivo_decisiones = "output/alertas_ids_para_verificacion.xlsx", base_original) {
  decisiones <- read_xlsx(archivo_decisiones) %>% filter(!is.na(Decision_Analista))
  if (nrow(decisiones) == 0) { cat("⚠️ No hay decisiones para aplicar.\n"); return(base_original) }
  
  bd_corregida <- base_original
  
  # Regla: Si decisión es "Mantener_ID1", reemplaza el ID2 (erróneo) por el ID1 (correcto)
  if ("Mantener_ID1" %in% decisiones$Decision_Analista) {
    reglas <- decisiones %>% filter(Decision_Analista == "Mantener_ID1") %>% select(ID_Sospechoso_2, Nuevo_ID = ID_Sospechoso_1)
    bd_corregida <- bd_corregida %>% left_join(reglas, by = c("Identificacion" = "ID_Sospechoso_ is.na(Nuevo_ID), Identificacion, Nuevo_ID)) %>% select(-Nuevo_ID)
  }
  
  # Regla: Si decisión es "Mantener_ID2", reemplaza el ID1 (erróneo) por el ID2 (correcto)
  if ("Mantener_ID2" %in% decisiones$Decision_Analista) {
    reglas <- decisiones %>% filter(Decision_Analista == "Mantener_ID2") %>% select(ID_Sospechoso_1, Nuevo_ID = ID_Sospechoso_2)
    bd_corregida <- bd_corregida %>% left_join(reglas, by = c("Identificacion" = "ID_Sospechoso_1")) %>%
      mutate(Identificacion = coalesce(Nuevo_ID, Identificacion)) %>% select(-Nuevo_ID)
  }
  
  cat("✓ Decisiones del analista aplicadas exitosamente.\n")
  return(bd_corregida)
}

# FUNCIÓN 2: Actualiza IDs faltantes usando el Excel corregido por el equipo de campo
# ADVERTENCIA: Se une por 'Nombre' Y 'Fuente_Datos' para evitar fusionar a dos "Juan Perez" distintos.
actualizar_ids_faltantes <- function(archivo_corregido, base_original) {
  ids_corregidos <- read_xlsx(archivo_corregido) %>%
    filter(!is.na(Identificacion) & Identificacion != "" & Identificacion != "NA")
  
  # Define columnas seguras para el cruce (Nombre es obligatorio, Fuente_Datos es opcional pero recomendado)
  cols_cruce <- intersect(c("Nombre", "Fuente_Datos"), names(ids_corregidos))
  
  bd_actualizada <- base_original %>%
    left_join(ids_corregidos %>% select(all_of(cols_cruce), ID_Nuevo = Identificacion), by = cols_cruce) %>%
    mutate(Identificacion = coalesce(ID_Nuevo, Identificacion)) %>%
    select(-ID_Nuevo)
  
  cat("✓", nrow(ids_corregidos), "IDs faltantes actualizados de forma segura.\n")
  return(bd_actualizada)
}


# ==============================================================================
# PARTE 4: CONTEO FINAL Y EXPORTACIÓN DE RESULTADOS
# ==============================================================================

# PASO INTERMEDIO: Aquí decides qué base usar. 
# Descomenta la línea de 'bd_corregida' SOLO si ya ejecutaste la función aplicar_decisiones()
# bd_final <- bd_corregida  
bd_final <- bd_unida # Por defecto usa la base sin corregir manualmente aún
data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACgAAAAkCAYAAAD7PHgWAAABBklEQVR4Xu2XMQrCQBBFBQvR6wgJHsEDpHVjBDvvoBhbI3bWCkZbFUyhFrYiEat0WgmC6AVkdQqbIVmWZAOi82C64b+/bDWZDEEQP4phTLMaa9d003bTGMgu1psF7JVGNzuWPdzs18GDz443rgrIcndXbvW8g1axGfZKo7P2eBXc+WB74a3FGXtiA1kwzfnpqTF7hL3SwDfAaz+BqvjkwYADe6WhglQwJlQwKVQwKakVTGOoYNL5z4JxwBlUMEwqAu9SwTCpCLxLBcOkIvCusoKT9/WFQ6OkIvCukoJwt5rO0sehUVIReBem6ng+OLBXmnKjn4PbGM5PeKnqgXIlo5vHXoL4Nl4ZYqbbEGA7+wAAAABJRU5ErkJggg==
# 4A. GENERACIÓN DE BASE DE CONTEO CONSOLIDADA
bd_conteo <- bd_final %>%
  group_by(Identificacion) %>%
  summarise(
    Nombre_Principal = first(Nombre),
    Veces_Aparece = n(),
    Programas_Participados = paste(unique(Fuente_Datos), collapse = ", "),
    Cantidad_Programas = n_distinct(Fuente_Datos),
    Nombres_Diferentes = n_distinct(Nombre),
    .groups = "drop"
  )

# 4B, 4C, 4D. MÉTRICAS BÁSICAS DE PARTICIPACIÓN
total_unicos <- nrow(bd_conteo)
multiples <- bd_conteo %>% filter(Cantidad_Programas > 1)
unico_prog <- bd_conteo %>% filter(Cantidad_Programas == 1)

cat("\n=== RESUMEN DE CONTEO ===")
cat("\nTotal únicos:", total_unicos)
cat("\nEn >1 programa:", nrow(multiples), "(", round(nrow(multiples)/total_unicos*100, 1), "%)")
cat("\nEn 1 programa:", nrow(unico_prog), "(", round(nrow(unico_prog)/total_unicos*100, 1), "%)\n")

# 4E. CLASIFICACIÓN DE CALIDAD DE DATOS
# Verifica si 'alertas_totales' existe para evitar errores si se saltó la Parte 3B
ids_en_revision <- if (exists("alertas_totales")) alertas_totales$ID_Sospechoso_1 else character(0)

bd_conteo <- bd_conteo %>%
  mutate(
    Estado_Verificacion = case_when(
      is.na(Identificacion) | Identificacion == "" | Identificacion == "0" | 
      Identificacion == "NA" | nchar(Identificacion) < 5 ~ "Pendiente_Verificacion",
      Identificacion %in% ids_en_revision ~ "En_Revision",
      TRUE ~ "Confirmado"
    )
  )

resumen_calidad <- bd_conteo %>%
  group_by(Estado_Verificacion) %>%
  summarise(Cantidad = n(), Porcentaje = round(n()/total_unicos*100, 2), .groups = "drop")

cat("\n=== CALIDAD DE DATOS ===\n")
print(resumen_calidad)

# 4F. EXPORTACIÓN FINAL DE ENTREGABLES
resumen_ejecutivo <- data.frame(
  Metrica = c("Total Únicos", "Múltiples Programas", "Un Solo Programa", 
              "Confirmados", "En Revisión", "Pendientes"),
  Cantidad = c(total_unicos, nrow(multiples), nrow(unico_prog),
               sum(resumen_calidad$Cantidad[resumen_calidad$Estado_Verificacion == "Confirmado"]),
               sum(resumen_calidad$Cantidad[resumen_calidad$Estado_Verificacion == "En_Revision"]),
               sum(resumen_calidad$Cantidad[resumen_calidad$Estado_Verificacion == "Pendiente_Verificacion"]))
)

write_xlsx(bd_conteo, "output/bd_conteo_completa.xlsx")
write_xlsx(resumen_ejecutivo, "output/resumen_ejecutivo.xlsx")
write_xlsx(multiples, "output/detalle_multiples_programas.xlsx")
