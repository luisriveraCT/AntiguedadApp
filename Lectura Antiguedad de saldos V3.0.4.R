rm(list=ls())
graphics.off()
cat("\014")
knitr::opts_chunk$set(echo = TRUE)
rmarkdown::render
options(scipen=999)
start_timer <- Sys.time()


#============================Remove old functions before each session (for development)=============
rm_functions <- function(env = .GlobalEnv) {
  n <- ls(envir = env, all.names = TRUE)
  f <- Filter(function(x) is.function(get(x, envir = env, inherits = FALSE)), n)
  if (length(f)) rm(list = f, envir = env)
  invisible(f)
}
# use:
rm_functions()#---------------------------------------------

# =========================================== Simpler installer ==================================
needed <- c("shiny","DBI","RSQLite","knitr","pool","ggtext","grid","RODBC","bslib",
            "DT","openxlsx","quantmod","readr","ggplot2","readxl","dplyr","tidyr",
            "shinyWidgets","scales","lubridate","stringr")
missing <- setdiff(needed, rownames(installed.packages()))
if (length(missing)) {
  install.packages(missing, type = "binary")
}
invisible(lapply(needed, library, character.only = TRUE))
# =================================================================================================

#========================================================== MAIN INSTALLER ========================================
# library(scales)
# libraries <- c("shiny", "DBI", "RSQLite","knitr", "renv", "pool", "ggtext", "grid", "RODBC", "bslib", "DT", "openxlsx", 
#               "magrittr", "quantmod", "readr", "ggplot2", "readxl", "dplyr", "tidyr", "shinyWidgets", "scales", "lubridate", "stringr")
# for (i in libraries) {
#   if (!i %in% installed.packages()) {
#     install.packages(i) # ---------------- Add , prompt=FALSE if packages are not loading properly or asking for approval.
#     update.packages(ask = FALSE)
#     lapply(i, library, character.only = T)
#   } else {
#     lapply(i, library, character.only = T)
#   }
# }
# rm(i)
#=================================================================================================================

#==================================================================== APP CONFIG =============================================
# === CONFIG: where to store the central SQLite DB ===


# Tries OneDrive for Business first; falls back to personal OneDrive; finally the app folder
find_db_dir <- function() {
  cand <- c(
    file.path(Sys.getenv("OneDriveCommercial", unset = ""),"Finanzas","Control de flujos NWS","AntiguedadApp"),
    file.path(Sys.getenv("OneDrive",           unset = ""),"Finanzas","Control de flujos NWS","AntiguedadApp"),
    file.path(getwd(), "AntiguedadApp")
  )
  cand <- cand[nzchar(cand)]
  for (p in cand) {
    p2 <- normalizePath(p, winslash = "/", mustWork = FALSE)
    if (dir.exists(p2) || dir.create(p2, recursive = TRUE, showWarnings = FALSE)) return(p2)
  }
  stop("No pude crear/encontrar la carpeta para la base SQLite.")
}
DB_DIR  <- find_db_dir()
DB_PATH <- file.path(DB_DIR, "moves.sqlite")
db_connect <- function() {
  DBI::dbConnect(RSQLite::SQLite(), DB_PATH)
}

init_moves_db <- function() {
  con <- db_connect(); on.exit(DBI::dbDisconnect(con), add = TRUE)
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS moves (
      Tipo TEXT NOT NULL,              -- 'AR' or 'AP'
      Empresa TEXT NOT NULL,
      Moneda  TEXT NOT NULL,
      Documento TEXT NOT NULL,
      FechaVenc_Proyectada DATE,
      last_updated TIMESTAMP,
      PRIMARY KEY (Tipo, Empresa, Moneda, Documento)
    );
  ")
  invisible(TRUE)
}
init_moves_db()







# SE IDENTIFICAN DOCUMENTOS ÚNICOS POR SU CARACTERÍSTICA: "DOCUMENTO". Los que no tengan dato en "documento" se incuirán sin revisión de duplicados.


# 🔧 For the Persistence helpers
DATA_DIR  <- file.path(getwd(), "data")
dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)
MOVES_PATH    <- file.path(DATA_DIR, "invoice_moves.rds")
MOVES_PATH_AP <- file.path(DATA_DIR, "invoice_moves_ap.rds")
INTERCO_PATH  <- file.path(DATA_DIR, "intercompany_settings.rds")


dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)

# quick write test (fail early if perms are missing)
try({
  tf <- file.path(DATA_DIR, paste0("._perm_test_", as.integer(Sys.time()), ".tmp"))
  writeBin(charToRaw("ok"), tf); file.remove(tf)
})



#------------- App's Theme: flatly  https://bootswatch.com/flatly/


# --- Load the file ---
# Option A: pick the file in a dialog
#path <- file.choose()

# Option B: set the path directly

#--------------------------------------------------- Set Working Directory.
#raw <- read_excel(path, sheet = 1, .name_repair = "minimal")



# --- Helpers: robust date & currency parsing for SAP exports ---




#============================ global designation HELPER ==========================
# null-coalesce infix used across helpers and server
`%||%` <- function(x, y) {
  if (is.null(x)) return(y)
  if (length(x) == 0L) return(y)
  if (length(x) == 1L && is.na(x)) return(y)
  x
}
#-----------------------------------------------------------------

# Parse dates that might be Excel serials (1900/1904 systems) or character like dd/mm/yyyy or dd.mm.yyyy
## --------- FILE DISCOVERY ---------
find_antiguedad_dir <- function(root = getwd()) {
  # Prefer a folder named exactly/loosely "ANTIGUEDAD" in the current project root
  dirs <- list.dirs(root, recursive = FALSE, full.names = TRUE)
  pick <- dirs[grepl("(?i)^Antigüedad$", basename(dirs))]         # exact
  if (!length(pick)) pick <- dirs[grepl("(?i)Antigüedad", basename(dirs))]  # contains
  if (length(pick)) pick[1] else root
}

# Map initials to company names
COMPANY_MAP <- c(
  "NG"  = "Networks Group",
  "NTS" = "Networks Trucking Services",
  "NCS" = "Networks Crossdocking Services",
  "N&L" = "Networks & Logistics",
  "NRS" = "Networks Realtors"
)

# List candidate Excel files.
# Matches both old and new naming, e.g.:
#   - "ANTIGUEDAD CROSSDOCKING 19.08.2025.xlsx"
#   - "Antigüedad de saldos de clientes NG 21.08.2025.xlsx"
list_antiguedad_files <- function(dir) {
  files <- list.files(
    dir,
    pattern = "(?i)^antig[uü]edad.*\\.(xlsx|xls)$",  # robust to ü / u and both patterns
    full.names = TRUE
  )
  # drop temp/lock files like "~$file.xlsx"
  files[!grepl("^~\\$", basename(files))]
}

# Extract company (from initials between 'clientes' and the date) and the date
# Example filename (no extension): "Antigüedad de saldos de clientes NG 21.08.2025"
extract_company_date <- function(path) {
  fn <- tools::file_path_sans_ext(basename(path))
  
  # regex: ... clientes [INITIALS] [DATE]
  # allow optional dash/colon after 'clientes', flexible separators in the date
  m <- stringr::str_match(
    fn,
    "(?i)clientes\\s*[-:]?\\s*(NG|NTS|NCS|N&L|NRS)\\s+(\\d{1,2}[\\./-]\\d{1,2}[\\./-]\\d{2,4})\\s*$"
  )
  
  # initials (uppercased)
  initials <- toupper(ifelse(!is.na(m[,2]), m[,2], NA_character_))
  
  # map to full company name; if unknown, fall back to initials or the raw name
  company <- if (!is.na(initials) && initials %in% names(COMPANY_MAP)) {
    COMPANY_MAP[[initials]]
  } else if (!is.na(initials)) {
    initials
  } else {
    # Fallback: try to pull something after "Antigüedad" if present, else use filename
    alt <- sub("(?i)^antig[uü]edad\\s+de\\s+saldos\\s+de\\s+clientes\\s+", "", fn, perl = TRUE)
    trimws(alt)
  }
  
  # parse date
  date_txt <- ifelse(!is.na(m[,3]), m[,3], NA_character_)
  if (!is.na(date_txt)) {
    date_std <- gsub("[._/]", "-", date_txt)
    dt <- suppressWarnings(lubridate::dmy(date_std))
    if (is.na(dt)) dt <- suppressWarnings(lubridate::ymd(date_std))
  } else {
    dt <- NA
  }
  
  list(company = company, date = dt)
}

#================================================Format HELPER ====================
fmt_money <- function(x) paste0("$ ", scales::number(x, big.mark = ",", accuracy = 0.01))
#--------------------------------------------------

#======================== Define clear AR/AP detectors + candidate lists ===========

## --------- READING / CLEANING (reuses your logic) ---------
parse_sap_date <- function(x) {
  if (inherits(x, "Date")) return(x)
  
  # Work on character; try numeric-as-text serials first
  xc   <- as.character(x)
  num  <- suppressWarnings(as.numeric(xc))
  out  <- as.Date(rep(NA_real_, length(xc)), origin = "1970-01-01")
  
  is_num <- !is.na(num)
  if (any(is_num)) {
    d1900 <- as.Date(num[is_num], origin = "1899-12-30")  # Excel 1900 system
    # fallback for obviously wrong ranges
    bad   <- d1900 < as.Date("1900-01-01") | d1900 > as.Date("2100-01-01")
    d1904 <- as.Date(num[is_num][bad], origin = "1904-01-01")
    d1900[bad] <- d1904
    out[is_num] <- d1900
  }
  
  if (any(!is_num)) {
    xs <- gsub("\\.", "/", xc[!is_num])  # 21.08.2025 -> 21/08/2025
    d1 <- suppressWarnings(lubridate::dmy(xs))
    d2 <- suppressWarnings(lubridate::ymd(xs))
    dd <- ifelse(!is.na(d1), d1, d2)
    out[!is_num] <- as.Date(dd)
  }
  
  out
}


to_currency_num <- function(x) {
  if (is.numeric(x)) return(x)
  x2 <- stringr::str_replace_all(x, "[^0-9,.-]", "")
  uses_comma_decimal <- any(stringr::str_detect(x2, ",\\d{1,2}$"), na.rm = TRUE)
  if (uses_comma_decimal) {
    x2 <- stringr::str_replace_all(x2, "\\.", "")
    x2 <- stringr::str_replace(x2, ",", ".")
  } else {
    x2 <- stringr::str_replace_all(x2, ",", "")
  }
  suppressWarnings(as.numeric(x2))
}

read_clean_antiguedad <- function(path) {
  meta <- extract_company_ledger(path)
  
  # Read ALL columns as text → avoids cross-file type mismatches
  raw  <- readxl::read_excel(
    path, sheet = 1, .name_repair = "minimal", col_types = "text"
  )
  
  # Parse known columns if present (they are text now)
  if ("Fecha de contabilización" %in% names(raw))
    raw[["Fecha de contabilización"]] <- parse_sap_date(raw[["Fecha de contabilización"]])
  if ("Fecha de vencimiento" %in% names(raw))
    raw[["Fecha de vencimiento"]]     <- parse_sap_date(raw[["Fecha de vencimiento"]])
  if ("Saldo vencido" %in% names(raw))
    raw[["Saldo vencido"]]            <- to_currency_num(raw[["Saldo vencido"]])
  if ("Abono futuro" %in% names(raw))
    raw[["Abono futuro"]]             <- to_currency_num(raw[["Abono futuro"]])
  
  # Standardize party & code (uses helpers you already added)
  df <- raw %>%
    standardize_party_ar() %>%        # creates/filled-down `Parte`
    standardize_codigo_ar()           # optional, fills `Código de cliente`
  
  # Ensure currency column Moneda
  currency_guess <- names(df)[stringr::str_detect(tolower(names(df)), "moneda|currency|divisa")]
  if (length(currency_guess) >= 1) {
    df <- dplyr::rename(df, Moneda = !!currency_guess[1])
  } else if (!"Moneda" %in% names(df)) {
    df$Moneda <- "MXN"
  }
  df <- df %>%
    dplyr::mutate(Moneda = toupper(trimws(as.character(Moneda)))) %>%
    tidyr::fill(Moneda, .direction = "down")
  
  # Ensure a Documento column exists
  df <- add_documento(df)
  
  # Attach metadata (filename date is gone; keep file mtime for dedupe)
  df_final <- df %>%
    dplyr::mutate(
      Empresa       = meta$company,
      Archivo       = basename(path),
      FechaArchivo  = as.Date(NA),
      ArchivoMtime  = meta$mtime,
      Tipo          = "AR"
    )
  
  return(df_final)
}



#=========================== read_clean_antig...() sibling for Accounts Payable===========
read_clean_pagar <- function(path) {
  meta <- extract_company_ledger(path)
  
  raw  <- readxl::read_excel(path, sheet = 1, .name_repair = "minimal", col_types = "text")
  
  if ("Fecha de contabilización" %in% names(raw))
    raw[["Fecha de contabilización"]] <- parse_sap_date(raw[["Fecha de contabilización"]])
  if ("Fecha de vencimiento" %in% names(raw))
    raw[["Fecha de vencimiento"]]     <- parse_sap_date(raw[["Fecha de vencimiento"]])
  
  if ("Saldo vencido" %in% names(raw))
    raw[["Saldo vencido"]]            <- to_currency_num(raw[["Saldo vencido"]])
  if ("Abono futuro" %in% names(raw))
    raw[["Abono futuro"]]             <- to_currency_num(raw[["Abono futuro"]])
  
  df <- raw %>%
    standardize_party_ap()   # <— IMPORTANT: this sets Parte from Nombre de acreedor
  # (keep any other AP-specific standardizations you already had)
  
  currency_guess <- names(df)[stringr::str_detect(tolower(names(df)), "moneda|currency|divisa")]
  if (length(currency_guess) >= 1) df <- dplyr::rename(df, Moneda = !!currency_guess[1]) else if (!"Moneda" %in% names(df)) df$Moneda <- "MXN"
  df <- df %>% dplyr::mutate(Moneda = toupper(trimws(as.character(Moneda)))) %>% tidyr::fill(Moneda, .direction = "down")
  
  df <- add_documento(df)
  
  df_final <- df %>%
    dplyr::mutate(
      Empresa       = meta$company,
      Archivo       = basename(path),
      FechaArchivo  = as.Date(NA),
      ArchivoMtime  = meta$mtime,
      Tipo          = "AP"
    )
  
  return(df_final)
}


#==================================================================================


process_antiguedad_files <- function(paths) {
  # Return a named list of data.frames, one per file, name includes company & date for clarity
  out <- lapply(paths, function(p) {
    df <- read_clean_antiguedad(p)
    key <- extract_company_date(p)
    nm  <- paste0(key$company,
                  if (!is.na(key$date)) paste0(" | ", format(key$date, "%Y-%m-%d")) else "",
                  " | ", basename(p))
    attr(df, "table_name") <- nm
    df
  })
  names(out) <- vapply(out, function(df) attr(df, "table_name"), character(1))
  out
}

#================================Processor for Accounts Payable==========================
process_pagar_files <- function(paths) {
  out <- lapply(paths, function(p) {
    df <- read_clean_pagar(p)
    key <- extract_company_date(p)
    nm  <- paste0(key$company,
                  if (!is.na(key$date)) paste0(" | ", format(key$date, "%Y-%m-%d")) else "",
                  " | ", basename(p))
    attr(df, "table_name") <- nm
    df
  })
  names(out) <- vapply(out, function(df) attr(df, "table_name"), character(1))
  out
}#=======================================================================================

#=========================================COMPANY MAP HELPER - classify files and extract company

# Detect ledger (AR/AP) and company initials from the FILE NAME (not the sheet)
# - AR if name has "clientes"
# - AP if name has "proveedores"
# - initials are the LAST occurrence of one of: NG, NTS, NCS, N&L, NRS
parse_filename_meta <- function(path, display_name = NULL) {
  fn <- tools::file_path_sans_ext(basename(display_name %||% path))
  fn_low <- tolower(fn)
  
  ledger <- if (grepl("\\bclientes\\b", fn_low, perl = TRUE)) {
    "AR"
  } else if (grepl("\\bproveedores\\b", fn_low, perl = TRUE)) {
    "AP"
  } else NA_character_
  
  # grab last occurrence of a known code (case-insensitive), incl. N&L
  pat <- "(?i)(?<![A-Za-z0-9])(?:NG|NTS|NCS|N\\&L|NRS)(?![A-Za-z0-9])"
  hits <- stringr::str_extract_all(fn, pat)[[1]]
  initials <- if (length(hits)) toupper(tail(gsub("(?i)", "", hits, perl = TRUE), 1)) else NA_character_
  
  company <- if (!is.na(initials) && initials %in% names(COMPANY_MAP)) COMPANY_MAP[[initials]] else initials
  
  list(ledger = ledger, initials = initials, company = company)
}

# Replacement for your old extract_* function (dates removed → FechaArchivo = NA)
# Uses only file name; still records file mtime for dedupe ordering.
extract_company_ledger <- function(path, display_name = NULL) {
  meta <- parse_filename_meta(path, display_name)
  mtime <- tryCatch(as.POSIXct(file.info(path)$mtime, tz = "UTC"), error = function(e) as.POSIXct(NA))
  list(company = meta$company, initials = meta$initials, ledger = meta$ledger, date = as.Date(NA), mtime = mtime)
}

# Split a vector of file paths into AR/AP based on name
split_paths_by_ledger <- function(paths) {
  if (!length(paths)) return(list(ar = character(0), ap = character(0), unknown = character(0)))
  metas <- lapply(paths, parse_filename_meta)
  ledger <- vapply(metas, function(m) m$ledger %||% NA_character_, character(1))
  ar <- paths[ledger == "AR"]
  ap <- paths[ledger == "AP"]
  unknown <- paths[is.na(ledger)]
  list(ar = ar, ap = ap, unknown = unknown)
}
#-------------------------------------------------------------------------------

# ========= Small helpers =========
currency_formatter <- function(cur) {
  cur <- toupper(trimws(cur))
  if (cur == "MXN") return(scales::label_dollar(prefix = "MX$", big.mark = ",", decimal.mark = ".", accuracy = 0.01))
  if (cur == "USD") return(scales::label_dollar(prefix = "$",   big.mark = ",", decimal.mark = ".", accuracy = 0.01))
  if (cur == "EUR") return(scales::label_dollar(prefix = "€",   big.mark = ",", decimal.mark = ".", accuracy = 0.01))
  # generic fallback with code suffix
  f <- scales::label_number(big.mark = ",", decimal.mark = ".", accuracy = 0.01)
  function(x) paste0(f(x), " ", cur)
}

#=========== Map click to Date helper =================
calendar_grid <- function(month_start) {
  month_start <- as.Date(lubridate::floor_date(as.Date(month_start), "month"))
  month_end   <- as.Date(lubridate::ceiling_date(month_start, "month") - lubridate::days(1))
  tibble::tibble(Fecha = seq.Date(month_start, month_end, by = "day")) %>%
    dplyr::mutate(
      wday = lubridate::wday(Fecha, week_start = 1),   # 1=Mon .. 7=Sun
      start_wday = lubridate::wday(month_start, week_start = 1),
      week = ((lubridate::day(Fecha) + start_wday - 2) %/% 7) + 1
    )
}#=============================================================


# Build a Spanish month label ========================================
mes_es <- function(date0) {
  meses <- c("enero","febrero","marzo","abril","mayo","junio",
             "julio","agosto","septiembre","octubre","noviembre","diciembre")
  paste0(meses[as.integer(format(date0, "%m"))], " ", format(date0, "%Y"))
}

#---------------------------Invoice guessing HELPER-----------------
guess_invoice_col <- function(df) {
  nms <- names(df)
  # common candidates (exact match first)
  candidates <- c(
    "Nº de documento","Número de documento","No. de documento","No. documento",
    "Documento","DocNum","DocEntry","Nº Factura","Número de factura","Factura"
  )
  hit <- candidates[candidates %in% nms][1]
  if (!is.na(hit)) return(hit)
  # regex fallback
  idx <- which(grepl("(?i)doc(ument|\\.)|factur", nms))
  if (length(idx)) return(nms[idx[1]])
  NULL
}

#==========================================Standardization HELPER==================
# Find a column by preferred names or regex
guess_col <- function(df, preferred = character(), regex = NULL) {
  nms <- names(df)
  hit <- preferred[preferred %in% nms][1]
  if (!is.na(hit)) return(hit)
  if (!is.null(regex)) {
    i <- which(grepl(regex, nms, ignore.case = TRUE))[1]
    if (length(i) && !is.na(i)) return(nms[i])
  }
  NULL
}

# Standardize AR "party" to Parte (cliente)
clean_string <- function(x) {
  x <- trimws(as.character(x))
  x[x %in% c("", "-", "—", "–", ".", "NA", "N/A", "****")] <- NA_character_
  x
}

# AR: ensure Parte (cliente) and Código de cliente exist, populate, and fill down safely
standardize_party_ar <- function(df) {
  name_col <- guess_col(
    df,
    preferred = c("Nombre del cliente","Cliente","Customer","Customer Name","CardName","Socio de negocios"),
    regex     = "(cliente|cardname|customer|socio.*neg)"
  )
  code_col <- guess_col(
    df,
    preferred = c("Código de cliente","Codigo de cliente","Código Cliente","Codigo Cliente","CardCode"),
    regex     = "(c[oó]digo.*cliente|cardcode)"
  )
  
  # 1) guarantee target columns exist
  if (!"Parte" %in% names(df)) df$Parte <- NA_character_
  if (!"Código de cliente" %in% names(df)) df$`Código de cliente` <- NA_character_
  
  # 2) populate from detected source columns (if found), then normalize
  if (!is.null(name_col)) df$Parte <- clean_string(df[[name_col]])
  if (!is.null(code_col)) df$`Código de cliente` <- clean_string(df[[code_col]])
  
  # 3) fill down *only* existing targets (any_of avoids errors)
  df %>%
    tidyr::fill(dplyr::any_of(c("Parte", "Código de cliente")), .direction = "down")
}


# Standardize AR "Código de cliente" (optional but nice)
standardize_codigo_ar <- function(df) {
  cod_col <- guess_col(
    df,
    preferred = c("Código de cliente","Codigo de cliente","Código Cliente","Codigo Cliente","CardCode"),
    regex     = "(codigo.*cliente|cardcode)"
  )
  if (!is.null(cod_col)) {
    df <- df %>%
      dplyr::mutate(`Código de cliente` = dplyr::na_if(trimws(as.character(.data[[cod_col]])), "")) %>%
      tidyr::fill(`Código de cliente`, .direction = "down")
  }
  df
}
#---------------------------------------------------------------------------------------------
#==================DEDUPE INVOICES HELPER ===========================
# Keep ONE row per (Empresa, Moneda, Documento, Fecha de vencimiento),
# choosing the newest snapshot (by FechaArchivo, then ArchivoMtime).
dedupe_invoices <- function(df) {
  # only dedupe where we have a usable Document ID
  has_doc <- !is.na(df$Documento) & nzchar(df$Documento)
  
  part_doc <- df[has_doc, ] %>%
    dplyr::arrange(
      dplyr::desc(!is.na(FechaArchivo)), dplyr::desc(FechaArchivo),
      dplyr::desc(!is.na(ArchivoMtime)), dplyr::desc(ArchivoMtime)
    ) %>%
    dplyr::group_by(Empresa, Moneda, Documento, `Fecha de vencimiento`) %>%
    dplyr::slice_head(n = 1) %>%
    dplyr::ungroup()
  
  # rows without Documento are left untouched (we can't safely collapse them)
  part_nodoc <- df[!has_doc, ]
  
  dplyr::bind_rows(part_doc, part_nodoc)
}
#============================================================================
# ===== AP: standardize vendor name (Parte) and keep vendor code separately HELPER=============

standardize_party_ap <- function(df) {
  # Prefer the human-readable vendor name
  vendor_name_col <- guess_col(
    df,
    preferred = c("Nombre de acreedor","Nombre del proveedor","Proveedor","Vendor","CardName","Socio de negocios"),
    regex     = "(acreedor|proveedor|vendor|cardname|socio.*neg)"
  )
  if (!is.null(vendor_name_col)) {
    df <- df %>%
      dplyr::mutate(Parte = dplyr::na_if(trimws(as.character(.data[[vendor_name_col]])), "")) %>%
      tidyr::fill(Parte, .direction = "down")
  } else if (!"Parte" %in% names(df)) {
    df$Parte <- NA_character_
  }
  
  # Keep the vendor code but DO NOT use it in the calendar
  codigo_col <- guess_col(
    df,
    preferred = c("Código de proveedor","Codigo de proveedor","CardCode","Código Proveedor","Codigo Proveedor"),
    regex     = "(c[oó]digo.*proveedor|cardcode)"
  )
  if (!is.null(codigo_col)) {
    df <- df %>%
      dplyr::mutate(`Código de proveedor` = dplyr::na_if(trimws(as.character(.data[[codigo_col]])), "")) %>%
      tidyr::fill(`Código de proveedor`, .direction = "down")
  }
  df
}
#---------------------------------------------------------------------------------

# ========= Calendar plotting function HELPER =============================

# ---- Improved calendar plot with wrapped labels and bold total ----

blue_theme <- list( #-------------------------------------------------CALENDAR THEME
  bg          = "white",
  tile_empty  = "white",
  tile_has    = "white",  # pale blue for days with amounts
  weekend     = "#F4F8FF",  # subtle weekend tint
  border      = "#0A58CA",  # tile border
  daynum      = "#0D6EFD",  # Bootstrap primary blue
  text        = "#0B2038",  # near-black navy
  divider     = "#B6C8FF",  # divider line
  title       = "#0D6EFD",
  subtitle    = "#6C757D",
  today_border= "#0A58CA"   # stronger blue for "today"
)


calendar_plot <- function(data_due, month_start, currency,#=================== CALENDAR PLOT
                          max_lines = 2,
                          wrap_width = 18,
                          name_max_chars = 30,
                          font_size_day = 4,
                          font_size_text = 3.0,
                          lineheight_text = 1.0,
                          show_currency_symbol = FALSE,
                          colors = blue_theme,
                          daynum_top_offset = 0.48,
                          content_top_offset = .30,
                          max_client_lines_total = 5,
                          title_prefix = "Cobros esperados") {
  
  # ---- Basic checks + normalize party column to `Parte`
  needed <- c("Fecha", "Moneda", "Importe")
  miss   <- setdiff(needed, names(data_due))
  if (length(miss)) stop("calendar_plot: faltan columnas: ", paste(miss, collapse = ", "))
  
  if (!"Parte" %in% names(data_due)) {
    if ("Nombre del cliente" %in% names(data_due)) {
      data_due <- dplyr::rename(data_due, Parte = `Nombre del cliente`)
    } else {
      stop("calendar_plot: falta la columna `Parte` (o `Nombre del cliente`).")
    }
  }
  
  month_start <- as.Date(lubridate::floor_date(as.Date(month_start), "month"))
  month_end   <- as.Date(lubridate::ceiling_date(month_start, "month") - lubridate::days(1))
  cur_norm    <- toupper(trimws(as.character(currency)))
  today       <- Sys.Date()
  
  fmt <- if (show_currency_symbol) currency_formatter(cur_norm) else
    scales::label_number(big.mark = ",", decimal.mark = ".", accuracy = 0.01)
  amount_prefix <- if (show_currency_symbol) "" else "$ "
  to_html_br <- function(x) gsub("\n", "<br>", x, fixed = TRUE)
  
  # ---- Filter to month + currency
  dcur <- data_due %>%
    dplyr::mutate(Moneda = toupper(trimws(Moneda))) %>%
    dplyr::filter(Moneda == cur_norm, Fecha >= month_start, Fecha <= month_end) %>%
    dplyr::mutate(Importe = abs(Importe))
  
  # ---- Per-client (Parte) & totals
  per_client <- dcur %>%
    dplyr::group_by(Fecha, Parte) %>%
    dplyr::summarise(Importe = sum(Importe, na.rm = TRUE), .groups = "drop")
  
  # ---- Daily totals
  daily_totals <- per_client %>%
    dplyr::group_by(Fecha) %>%
    dplyr::summarise(Total = sum(Importe, na.rm = TRUE), .groups = "drop")
  
  # ---- Top-N labels
  labels <- per_client %>%
    dplyr::arrange(Fecha, dplyr::desc(Importe)) %>%
    dplyr::group_by(Fecha) %>%
    dplyr::summarise(
      label_lines = {
        # pick() selects columns from the *current group* in dplyr >= 1.1
        dat <- dplyr::pick(Parte, Importe)
        top <- utils::head(dat, max_lines)
        
        nm  <- stringr::str_trunc(top$Parte, name_max_chars)
        nm  <- stringr::str_wrap(nm, width = wrap_width)
        nm  <- to_html_br(nm)
        
        lines <- paste0(nm, "<br>", amount_prefix, fmt(top$Importe))
        
        extra <- nrow(dat) - nrow(top)
        if (extra > 0) lines <- c(lines, paste0("+ ", extra, " más…"))
        paste(lines, collapse = "<br>")
      },
      .groups = "drop"
    )
  
  
  daily <- dplyr::full_join(labels, daily_totals, by = "Fecha") %>%
    dplyr::mutate(
      label = dplyr::case_when(
        is.na(Total) ~ NA_character_,
        is.na(label_lines) | label_lines == "" ~ paste0(
          "<span style='color:", colors$divider, "'>———</span><br>",
          "<b>Total: ", amount_prefix, fmt(Total), "</b>"
        ),
        TRUE ~ paste0(
          label_lines, "<br>",
          "<span style='color:", colors$divider, "'>———</span><br>",
          "<b>Total: ", amount_prefix, fmt(Total), "</b>"
        )
      )
    ) %>% dplyr::select(Fecha, label, Total)
  
  # ---- Calendar grid with weekend tint
  days <- tibble::tibble(Fecha = seq.Date(month_start, month_end, by = "day")) %>%
    dplyr::mutate(
      wday = lubridate::wday(Fecha, week_start = 1),
      start_wday = lubridate::wday(month_start, week_start = 1),
      week = ((lubridate::day(Fecha) + start_wday - 2) %/% 7) + 1,
      is_weekend = wday >= 6
    ) %>%
    dplyr::left_join(daily, by = "Fecha") %>%
    dplyr::mutate(
      tile_fill = dplyr::case_when(
        is_weekend                        ~ colors$weekend,
        !is.na(Total) & Total > 0         ~ colors$tile_has,
        TRUE                              ~ colors$tile_empty
      )
    )
  
  ggplot(days, aes(x = wday, y = week)) +
    geom_tile(aes(fill = tile_fill), color = colors$border) +
    scale_fill_identity() +
    geom_tile(
      data = ~ dplyr::filter(.x, Fecha == today),
      fill = NA, color = colors$today_border, linewidth = 1.1
    ) +
    geom_text(
      aes(label = lubridate::day(Fecha)),
      hjust = 0, vjust = 1,
      nudge_x = -0.46, nudge_y = daynum_top_offset,
      size = font_size_day, fontface = "bold", color = colors$daynum
    ) +
    ggtext::geom_richtext(
      aes(label = label),
      hjust = 0, vjust = 1,
      nudge_x = -0.46, nudge_y = content_top_offset,
      size = font_size_text, lineheight = lineheight_text,
      fill = NA, label.size = 0, label.color = NA,
      label.padding = grid::unit(c(0,0,0,0), "lines"),
      label.r = grid::unit(0, "pt"),
      colour = colors$text, na.rm = TRUE
    ) +
    scale_x_continuous(
      breaks = 1:7, labels = c("Lun","Mar","Mié","Jue","Vie","Sáb","Dom"),
      expand = c(0, 0)
    ) +
    scale_y_reverse(expand = c(0, 0)) +
    coord_equal() +
    labs(
      title = paste0(title_prefix, " – ", mes_es(month_start), " – ", cur_norm),
      subtitle = "Días con montos resaltados • Total = TODOS los de ese día",
      x = NULL, y = NULL
    ) +
    theme_minimal(base_size = 12) +
    theme(
      panel.grid       = element_blank(),
      panel.background = element_rect(fill = colors$bg, colour = NA),
      plot.background  = element_rect(fill = colors$bg, colour = NA),
      axis.text.y      = element_blank(),
      axis.text.x = ggtext::element_markdown(size = 15, face = "bold"),
      axis.ticks       = element_blank(),
      plot.title       = element_text(face = "bold", colour = colors$title, size = 14,
                                      margin = margin(t = 8, b = 8)),
      plot.subtitle    = element_text(colour = colors$subtitle),
      plot.margin      = margin(12, 18, 8, 18),
    )
}


#==================================Persistence HELPER=====================
MOVES_PATH <- file.path(DATA_DIR, "invoice_moves.rds")
if (!dir.exists(DATA_DIR)) dir.create(DATA_DIR, recursive = TRUE)

save_moves <- function(x) {
  dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)
  
  final <- MOVES_PATH
  bak   <- paste0(MOVES_PATH, ".bak")
  tmp   <- tempfile("moves_", tmpdir = DATA_DIR, fileext = ".rds.tmp")
  
  # 1) write to a temp file in the same directory
  saveRDS(x, tmp)
  
  # 2) rotate existing file out of the way (Windows cannot overwrite on rename)
  if (file.exists(bak)) unlink(bak)
  if (file.exists(final)) {
    ok1 <- file.rename(final, bak)
    if (!ok1) warning("No pude rotar el archivo existente: ", final)
  }
  
  # 3) install the new file (prefer rename; fallback to copy)
  ok2 <- file.rename(tmp, final)
  if (!ok2) {
    ok3 <- file.copy(tmp, final, overwrite = TRUE)
    unlink(tmp)
    if (!ok3) stop("No pude escribir el archivo de movimientos en: ", final)
  }
  
  # 4) cleanup backup
  if (file.exists(bak)) unlink(bak)
  
  invisible(final)
}

#======================================== SETTINGS HELPER ========================================================
# --- Intercompany settings persistence ---
INTERCO_PATH <- file.path(DATA_DIR, "intercompany_settings.rds")

# Normalize codes like " NG-01 " -> "NG01"
normalize_code <- function(x) toupper(gsub("[^A-Z0-9]", "", trimws(as.character(x))))

# Tri-state filter: mode = "exclude" | "include" | "only"
apply_ic_filter <- function(df, mode = "exclude", code_col = NULL, ic_codes_norm = character(0)) {
  if (is.null(code_col) || !code_col %in% names(df) || length(ic_codes_norm) == 0 || mode == "include") {
    return(df)  # no-op
  }
  codes <- normalize_code(df[[code_col]])
  is_ic <- codes %in% ic_codes_norm
  if (identical(mode, "exclude")) {
    df[!is_ic | is.na(is_ic), , drop = FALSE]
  } else { # "only"
    df[ is_ic & !is.na(is_ic), , drop = FALSE]
  }
}

# ======================================================= Excel management HELPERS .xslx ============
safe_read_ar <- function(p) {
  tryCatch({
    df  <- read_clean_antiguedad(p)
    key <- extract_company_date(p)
    nm  <- paste0(
      key$company,
      if (!is.na(key$date)) paste0(" | ", format(key$date, "%Y-%m-%d")) else "",
      " | ", basename(p)
    )
    attr(df, "table_name") <- nm
    attr(df, "path")       <- p
    df
  }, error = function(e) {
    warning(sprintf("[AR] %s: %s", basename(p), conditionMessage(e)))
    attr(NULL, "path") <- p
    NULL
  })
}

process_antiguedad_files <- function(paths) {
  res <- lapply(paths, safe_read_ar)
  ok  <- Filter(Negate(is.null), res)
  if (!length(ok)) stop("No se pudo leer ningún archivo válido (CxC).")
  
  names(ok) <- vapply(ok, function(df) attr(df, "table_name"), character(1))
  
  # Notify about skipped files (if any)
  read_paths <- vapply(ok, function(df) attr(df, "path"), character(1))
  skipped    <- setdiff(paths, read_paths)
  if (length(skipped)) {
    showNotification(
      paste0("Se omitieron ", length(skipped), " archivo(s) inválido(s): ",
             paste(basename(skipped), collapse = ", ")),
      type = "warning", duration = 8
    )
  }
  ok
}

# ===================== now for AP
safe_read_ap <- function(p) {
  tryCatch({
    df  <- read_clean_pagar(p)
    key <- extract_company_date(p)
    nm  <- paste0(
      key$company,
      if (!is.na(key$date)) paste0(" | ", format(key$date, "%Y-%m-%d")) else "",
      " | ", basename(p)
    )
    attr(df, "table_name") <- nm
    attr(df, "path")       <- p
    df
  }, error = function(e) {
    warning(sprintf("[AP] %s: %s", basename(p), conditionMessage(e)))
    attr(NULL, "path") <- p
    NULL
  })
}

process_pagar_files <- function(paths) {
  res <- lapply(paths, safe_read_ap)
  ok  <- Filter(Negate(is.null), res)
  if (!length(ok)) stop("No se pudo leer ningún archivo válido (CxP).")
  
  names(ok) <- vapply(ok, function(df) attr(df, "table_name"), character(1))
  
  read_paths <- vapply(ok, function(df) attr(df, "path"), character(1))
  skipped    <- setdiff(paths, read_paths)
  if (length(skipped)) {
    showNotification(
      paste0("Se omitieron ", length(skipped), " archivo(s) inválido(s): ",
             paste(basename(skipped), collapse = ", ")),
      type = "warning", duration = 8
    )
  }
  ok
}
#---------------------------------------------------------------------------------------------------



#------------------------------------------------ Intercompany Reactive function

load_interco <- function() {
  if (file.exists(INTERCO_PATH)) {
    out <- try(readRDS(INTERCO_PATH), silent = TRUE)
    if (inherits(out, "try-error") || !is.list(out)) out <- list(ar_clients = character(), ap_suppliers = character())
  } else {
    out <- list(ar_clients = character(), ap_suppliers = character())
  }
  # normalize
  out$ar_clients   <- normalize_code(out$ar_clients)
  out$ap_suppliers <- normalize_code(out$ap_suppliers)
  out
}

save_interco <- function(lst) {
  lst$ar_clients   <- normalize_code(lst$ar_clients %||% character())
  lst$ap_suppliers <- normalize_code(lst$ap_suppliers %||% character())
  dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)
  tmp <- paste0(INTERCO_PATH, ".tmp")
  saveRDS(lst, tmp)
  file.rename(tmp, INTERCO_PATH)
}
#---------------------------------------------------------------------------------------------

#============================Now the same Persistence but for Accounts Payable===========
MOVES_PATH_AP <- file.path(DATA_DIR, "invoice_moves_ap.rds")

load_moves_ap <- function() {
  if (file.exists(MOVES_PATH_AP)) readRDS(MOVES_PATH_AP) else empty_moves
}

save_moves_ap <- function(x) {  # atomic-style, like your AR save_moves()
  dir.create(DATA_DIR, showWarnings = FALSE, recursive = TRUE)
  final <- MOVES_PATH_AP
  bak   <- paste0(final, ".bak")
  tmp   <- tempfile("moves_ap_", tmpdir = DATA_DIR, fileext = ".rds.tmp")
  saveRDS(x, tmp)
  if (file.exists(bak)) unlink(bak)
  if (file.exists(final)) file.rename(final, bak)
  ok <- file.rename(tmp, final)
  if (!ok) { file.copy(tmp, final, overwrite = TRUE); unlink(tmp) }
  if (file.exists(bak)) unlink(bak)
  invisible(final)
}
#============================================================================


empty_moves <- tibble::tibble(
  Empresa = character(),
  Moneda  = character(),
  Documento = character(),
  FechaVenc_Proyectada = as.Date(character()),
  last_updated = as.POSIXct(character())
)

load_moves <- function() {
  if (file.exists(MOVES_PATH)) readRDS(MOVES_PATH) else empty_moves
}


# rows_upsert fallback (for dplyr < 1.1)
upsert_moves <- function(db, rows) {
  if (nrow(rows) == 0) return(db)
  if (utils::packageVersion("dplyr") >= "1.1.0") {
    return(dplyr::rows_upsert(db, rows, by = c("Empresa","Moneda","Documento")))
  }
  key_new <- paste(rows$Empresa, rows$Moneda, rows$Documento, sep="|")
  key_db  <- paste(db$Empresa,   db$Moneda,  db$Documento,  sep="|")
  match_db <- match(key_new, key_db)
  
  to_update <- !is.na(match_db)
  if (any(to_update)) db[ match_db[to_update], ] <- rows[to_update, ]
  if (any(!to_update)) db <- dplyr::bind_rows(db, rows[!to_update, ])
  db
}

# Add a standardized 'Documento' column using your guesser
# ==== Ensure a 'Documento' column exists ====
add_documento <- function(df) {
  inv <- guess_invoice_col(df)
  if (!is.null(inv) && inv %in% names(df)) {
    df$Documento <- as.character(df[[inv]])
  } else if (!"Documento" %in% names(df)) {
    df$Documento <- NA_character_
  }
  df
}
#===============================================================================

# Guess the folder and files once (outside server)
dir_antiguedad  <- find_antiguedad_dir()
candidate_files <- list_antiguedad_files(dir_antiguedad)

split <- split_paths_by_ledger(candidate_files)
candidate_files_ar <- split$ar
candidate_files_ap <- split$ap

if (length(split$unknown)) {
  message("Archivos no clasificados (ni 'clientes' ni 'proveedores' en el nombre):")
  message(paste0(" - ", basename(split$unknown), collapse = "\n"))
}

ui <- fluidPage(
  theme = bslib::bs_theme(version = 5, bootswatch = "flatly"),
  tabsetPanel(id = "ledger", type = "tabs",
              
              # ===== AR: Cuentas por cobrar =====
              tabPanel("Cuentas por cobrar",
                       fluidRow(
                         # --- AR (Cuentas por cobrar) sidebar ---
                         column(4,
                                h4("Archivos ANTIGUEDAD (CxC)"),
                                helpText("Preseleccionados desde: ", dir_antiguedad),
                                checkboxGroupInput(
                                  "files_pick_ar", "Selecciona archivos (clientes)",
                                  choices  = setNames(candidate_files_ar, basename(candidate_files_ar)),
                                  selected = candidate_files_ar
                                ),
                                fileInput("more_files_ar", "Agregar otros (.xlsx/.xls)", multiple = TRUE,
                                          accept = c(".xlsx", ".xls")),
                                actionButton("process_files_ar", "Procesar archivos"),
                                tags$hr(),
                                shinyWidgets::airMonthpickerInput("month_ar", "Mes", value = Sys.Date(), autoClose = TRUE),
                                radioButtons("amount_kind_ar","Importe a mostrar",
                                             choices=c("Saldo vencido","Abono futuro"),
                                             selected="Saldo vencido", inline=TRUE),
                                checkboxInput("show_invoices_ar","Mostrar facturas individuales", FALSE),
                                actionLink("edit_interco", "Configurar intercompany", icon = icon("gear")),
                                shinyWidgets::radioGroupButtons(
                                  inputId  = "interco_mode_ar",
                                  label    = "Intercompany",
                                  choices  = c("Excluir" = "exclude", "Incluir" = "include", "Sólo IC" = "only"),
                                  selected = "exclude",
                                  justified = TRUE,
                                  status   = "primary",
                                  size     = "sm"
                                ),
                                
                                uiOutput("currency_ui_ar")
                         )
                         ,
                         column(8, plotOutput("cal_ar", height = 700, click = "cal_click_ar"))
                       ),
              ),
              
              # ===== AP: Cuentas por pagar =====
              tabPanel("Cuentas por pagar",
                       fluidRow(
                         column(4,
                                h4("Archivos ANTIGÜEDAD (CxP)"),
                                helpText("Elige o agrega archivos de proveedores"),
                                checkboxGroupInput(
                                  "files_pick_ap", "Selecciona archivos (proveedores)",
                                  choices  = setNames(candidate_files_ap, basename(candidate_files_ap)),
                                  selected = candidate_files_ap
                                ),
                                fileInput("more_files_ap", "Agregar otros (.xlsx/.xls)", multiple = TRUE,
                                          accept = c(".xlsx", ".xls")),
                                actionButton("process_files_ap", "Procesar archivos"),
                                tags$hr(),
                                shinyWidgets::airMonthpickerInput("month_ap", "Mes", value = Sys.Date(), autoClose = TRUE),
                                radioButtons("amount_kind_ap","Importe a mostrar",
                                             choices=c("Saldo vencido","Abono futuro"),
                                             selected="Saldo vencido", inline=TRUE),
                                checkboxInput("show_invoices_ap","Mostrar facturas individuales", FALSE),
                                uiOutput("currency_ui_ap"),
                                shinyWidgets::radioGroupButtons(
                                  inputId  = "interco_mode_ap",
                                  label    = "Intercompany",
                                  choices  = c("Excluir" = "exclude", "Incluir" = "include", "Sólo IC" = "only"),
                                  selected = "exclude",
                                  justified = TRUE,
                                  status   = "primary",
                                  size     = "sm"
                                )
                         ),
                         column(8, plotOutput("cal_ap", height = 700, click = "cal_click_ap"))
                       )
              ),
              
  )
)



server <- function(input, output, session) {
  
  interco_settings <- reactiveVal(load_interco()) #======== INTERCOMPANY =============================
  
  observeEvent(input$edit_interco, {
    cur <- interco_settings() # --------- Reads current values
    showModal(modalDialog( # -------------- Show the modal
      title = "Configurar intercompany",
      size = "m", easyClose = TRUE,
      footer = tagList(
        modalButton("Cancelar"),
        actionButton("save_interco", "Guardar", class = "btn btn-primary")
      ),
      tagList(
        helpText("Ingresa códigos, uno por línea. Se comparan sin espacios y en mayúsculas."),
        fluidRow(
          column(6,
                 tags$label("Códigos de clientes (CxC)"),
                 textAreaInput("ic_clients_txt", NULL, 
                               value = paste(cur$ar_clients, collapse = "\n"), rows = 10, width = "100%")
          ),
          column(6,
                 tags$label("Códigos de proveedores (CxP)"),
                 textAreaInput("ic_suppliers_txt", NULL, 
                               value = paste(cur$ap_suppliers, collapse = "\n"), rows = 10, width = "100%")
          )
        )
      )
    ))
  })
  
  observeEvent(input$save_interco, { # ------------------------------- saves intercompany data and updates Settings.
    clients   <- normalize_code(unlist(strsplit(input$ic_clients_txt   %||% "", "\n", fixed = TRUE)))
    suppliers <- normalize_code(unlist(strsplit(input$ic_suppliers_txt %||% "", "\n", fixed = TRUE)))
    clients   <- clients[nzchar(clients)]
    suppliers <- suppliers[nzchar(suppliers)]
    cfg <- list(ar_clients = unique(clients), ap_suppliers = unique(suppliers))
    save_interco(cfg)
    interco_settings(cfg)
    removeModal()
    showNotification("Intercompany guardado.", type = "message")
  })#----------------------------------------------------------------INTERCOMPANY------------------------
  
  #-------------- Handlers ------------- used to optimize the use of observers and render times -------------
  # One place to track modal-scoped observers so we can destroy them
  # AR (invoice mode + grouped mode)
  obs_sel_ar        <- reactiveVal(NULL)  # selection counters (invoice mode)
  obs_move_ar_inv   <- reactiveVal(NULL)  # move button (invoice mode)
  obs_sel_ar_grp    <- reactiveVal(NULL)  # selection counters (grouped mode)
  obs_move_ar_grp   <- reactiveVal(NULL)  # move button (grouped mode)
  
  # AP (invoice mode + grouped mode)
  obs_sel_ap        <- reactiveVal(NULL)
  obs_move_ap_inv   <- reactiveVal(NULL)
  obs_sel_ap_grp    <- reactiveVal(NULL)
  obs_move_ap_grp   <- reactiveVal(NULL)
  #-----------------------------------------------------
  # ============================================ AR state ============================================
  files_selected_ar     <- reactiveVal(candidate_files_ar)
  tables_by_company_ar  <- reactiveVal(NULL)
  df_raw_multi_ar       <- reactiveVal(NULL)
  moves_db_ar           <- reactiveVal(load_moves())        # AR persistence (invoice_moves.rds)
  rv_ar <- reactiveValues(day_map = NULL, day_date = NULL)
  # optional: quick log
  observe({
    db <- moves_db_ar()
    message("Moves loaded: ", nrow(db))
  })
  
  # Stores the *display* name for each temp path
  files_labels_ar <- reactiveVal(setNames(character(0), character(0)))
  files_labels_ap <- reactiveVal(setNames(character(0), character(0)))
  
  
  # Optional log (fixed to use moves_db_ar)
  observe({
    db <- moves_db_ar()
    message("Moves loaded (AR): ", nrow(db))
  }) #----------------------------------------------- AR
  
 # ============================================================================= AR ======================================================================
  #================================= "MOVER" TOOL HELPER ==================
  # --- AR helper: apply a move; if new_date == original, clear the move instead of upserting
  apply_move_ar <- function(selected_keys, new_date) {
    # selected_keys must have: Empresa, Moneda, Documento
    df <- df_raw_multi_ar()
    db <- moves_db_ar()
    
    # Map each doc to its original date
    orig_map <- df %>%
      dplyr::select(Empresa, Moneda, Documento, FechaVenc_Original) %>%
      dplyr::distinct()
    
    keys <- selected_keys %>%
      dplyr::distinct(Empresa, Moneda, Documento) %>%
      dplyr::left_join(orig_map, by = c("Empresa","Moneda","Documento")) %>%
      dplyr::mutate(
        FechaVenc_Proyectada = as.Date(new_date),
        last_updated         = Sys.time()
      )
    
    # Split into: clear (revert to original) vs upsert (projected != original)
    to_clear  <- keys %>% dplyr::filter(FechaVenc_Proyectada == FechaVenc_Original)
    to_upsert <- keys %>% dplyr::filter(FechaVenc_Proyectada != FechaVenc_Original)
    
    # ---- Persist DB ----
    if (nrow(to_clear)) {
      # remove any existing move rows for these docs
      db <- dplyr::anti_join(db,
                             to_clear %>% dplyr::select(Empresa, Moneda, Documento),
                             by = c("Empresa","Moneda","Documento")
      )
    }
    if (nrow(to_upsert)) {
      # upsert (insert or update) projected date
      stopifnot(exists("upsert_moves", mode = "function"))
      db <- upsert_moves(
        db,
        to_upsert %>% dplyr::select(Empresa, Moneda, Documento, FechaVenc_Proyectada, last_updated)
      )
    }
    
    moves_db_ar(db)
    save_moves(db)
    
    # ---- Update in-memory df so UI refreshes immediately ----
    idx_for <- function(keys_df) {
      if (!nrow(keys_df)) return(integer(0))
      dplyr::inner_join(
        df %>% dplyr::mutate(.idx = dplyr::row_number()) %>%
          dplyr::select(.idx, Empresa, Moneda, Documento),
        keys_df %>% dplyr::select(Empresa, Moneda, Documento),
        by = c("Empresa","Moneda","Documento")
      )$.idx
    }
    
    i_clear  <- idx_for(to_clear)
    i_upsert <- idx_for(to_upsert)
    
    if (length(i_clear)) {
      df$FechaVenc_Proyectada[i_clear] <- as.Date(NA)
      df$FechaEff[i_clear]             <- df$FechaVenc_Original[i_clear]
    }
    if (length(i_upsert)) {
      df$FechaVenc_Proyectada[i_upsert] <- as.Date(new_date)
      df$FechaEff[i_upsert]             <- as.Date(new_date)
    }
    
    df_raw_multi_ar(df)
  }
  
  # AR: pick/unpick files -------------------------------
  observeEvent(input$files_pick_ar, {
    files_selected_ar(input$files_pick_ar %||% character(0))
  }, ignoreInit = TRUE)
  
  # AR: add uploaded files ---------------------------
  observeEvent(input$more_files_ar, {
    df <- req(input$more_files_ar)  # data.frame: name, datapath, type, size
    
    # 1) Only accept Excel
    keep <- tolower(tools::file_ext(df$name)) %in% c("xlsx", "xls")
    if (any(!keep)) {
      bad <- df$name[!keep]
      showNotification(
        paste0("Archivo(s) no Excel ignorado(s): ", paste(bad, collapse = ", ")),
        type = "warning"
      )
    }
    if (!any(keep)) return(invisible(NULL))
    
    # 2) Normalize paths and labels
    new_paths  <- normalizePath(df$datapath[keep], winslash = "/", mustWork = FALSE)
    new_labels <- df$name[keep]
    
    # 3) Update label map (path -> filename)
    lbl_map <- files_labels_ar()
    lbl_map[new_paths] <- new_labels
    files_labels_ar(lbl_map)
    
    # 4) Merge with existing selection
    new_all <- unique(c(files_selected_ar(), new_paths))
    files_selected_ar(new_all)
    
    # 5) Build choices with safe, non-NA names (fallback to basename)
    choices <- new_all
    names(choices) <- vapply(choices, function(p) {
      nm <- lbl_map[[p]]
      if (is.null(nm) || is.na(nm) || !nzchar(nm)) basename(p) else nm
    }, character(1))
    
    updateCheckboxGroupInput(
      session, "files_pick_ar",
      choices  = choices,
      selected = new_all
    )
  }, ignoreInit = TRUE)
  
  #------------------------------------------
  
  # =================================== AR: process files -> combined df =============================
  observeEvent(input$process_files_ar, {
    tryCatch({
      paths <- files_selected_ar()
      validate(need(length(paths) > 0, "Selecciona al menos un archivo (CxC)"))
      
      tabs <- process_antiguedad_files(paths)
      if (!length(tabs) || !all(vapply(tabs, is.data.frame, logical(1)))) {
        stop("No se pudo leer ningún archivo válido (CxC).")
      }
      tables_by_company_ar(tabs)
      
      combined_df <- dplyr::bind_rows(tabs, .id = "Tabla") %>%
        standardize_party_ar() %>%          # << ensure Parte from 'Nombre del cliente' + fill down
        standardize_codigo_ar() %>%         # << ensure 'Código de cliente' + fill down
        add_documento() %>%
        dplyr::mutate(
          Moneda  = toupper(trimws(Moneda)),
          `Fecha de vencimiento` = as.Date(`Fecha de vencimiento`),
          FechaVenc_Original     = `Fecha de vencimiento`
        ) %>%
        dedupe_invoices() %>%
        dplyr::left_join(moves_db_ar(), by = c("Empresa", "Moneda", "Documento")) %>%
        dplyr::mutate(
          FechaVenc_Proyectada = as.Date(FechaVenc_Proyectada),
          FechaEff             = dplyr::coalesce(FechaVenc_Proyectada, FechaVenc_Original),
          .row_id              = dplyr::row_number()
        )
      
      
      message("AR combined_df rows: ", nrow(combined_df))
      df_raw_multi_ar(combined_df)
      
      output$currency_ui_ar <- renderUI({
        selectInput("cur_ar", "Moneda", choices = sort(unique(combined_df$Moneda)))
      })
    }, error = function(e) {
      showModal(modalDialog(title = "Error al procesar (CxC)", paste(conditionMessage(e)), easyClose = TRUE))
    })
  }, ignoreInit = TRUE) #------------------------------------------------------------ AR
  
  # AR: currency picker whenever data changes
  observeEvent(df_raw_multi_ar(), {
    d <- df_raw_multi_ar()
    output$currency_ui_ar <- renderUI({
      selectInput("cur_ar", "Moneda", choices = sort(unique(d$Moneda)))
    })
  }, ignoreInit = TRUE)
  
  # AR: build day x client table based on selected amount ========== AR PIPELINE <- data flow that feeds AR calendar.
  df_due_multi_ar <- reactive({
    d <- req(df_raw_multi_ar())
    amt <- input$amount_kind_ar %||% "Saldo vencido"
    validate(need(amt %in% names(d), paste("No encuentro la columna:", amt)))
    
    # ensure name present (your existing fallback logic is fine if you already have it)
    if (!"Parte" %in% names(d) || all(is.na(d$Parte))) {
      name_col <- guess_col(
        d,
        preferred = c("Nombre del cliente","Cliente","Customer","CardName","Socio de negocios"),
        regex     = "(cliente|cardname|customer|socio.*neg)"
      )
      if (!is.null(name_col)) d$Parte <- d[[name_col]]
    }
    if (!"Parte" %in% names(d)) d$Parte <- NA_character_
    d$Parte <- dplyr::coalesce(dplyr::na_if(d$Parte, ""), d$`Código de cliente`)
    
    d %>%
      dplyr::mutate(
        Importe = abs(tidyr::replace_na(.data[[amt]], 0)),  # << force positive here
        Fecha   = as.Date(FechaEff),
        Moneda  = toupper(trimws(Moneda))
      ) %>%
      dplyr::filter(!is.na(Fecha)) %>%
      dplyr::group_by(Fecha, Moneda, Parte) %>%
      dplyr::summarise(Importe = sum(Importe, na.rm = TRUE), .groups = "drop")
  })
  
  
  
  # AR: calendar plot
  output$cal_ar <- renderPlot({
    req(df_due_multi_ar())
    # guard month input coming from airMonthpickerInput
    mstart <- suppressWarnings(lubridate::floor_date(as.Date(input$month_ar), "month"))
    validate(
      need(!is.na(mstart), "Selecciona un mes válido"),
      need(!is.null(input$cur_ar), "Elige una moneda")
    )
    
    d <- df_due_multi_ar() %>% dplyr::filter(Moneda == toupper(trimws(input$cur_ar)))
    validate(need(nrow(d) > 0, "No hay datos para ese mes/moneda"))
    
    calendar_plot(d,
                  month_start = mstart,
                  currency    = input$cur_ar,
                  max_lines   = 2,
                  title_prefix = "Cobros esperados")
  })
  
  #========================================================================================================================================================
  # AR: click -> modal (grouped view or invoice view with checkboxes + move) #======= Click handler =======================================================
  #========================================================================================================================================================
  observeEvent(input$cal_click_ar, {
    d_raw <- req(df_raw_multi_ar())
    cur   <- toupper(trimws(input$cur_ar))
    amt   <- input$amount_kind_ar %||% "Saldo vencido"
    
    # Map click -> date
    wday_clicked <- round(input$cal_click_ar$x)
    week_clicked <- round(input$cal_click_ar$y)
    if (is.na(wday_clicked) || is.na(week_clicked)) return(NULL)
    
    mstart  <- lubridate::floor_date(as.Date(input$month_ar), "month")
    grid    <- calendar_grid(mstart)
    day_row <- dplyr::filter(grid, wday == !!wday_clicked, week == !!week_clicked)
    if (nrow(day_row) != 1) return(NULL)
    sel_date <- day_row$Fecha[[1]]
    
    # Base rows for that day/currency
    detail_raw <- d_raw %>%
      dplyr::mutate(
        FechaEff = as.Date(FechaEff),
        Moneda   = toupper(trimws(Moneda)),
        Importe  = tidyr::replace_na(.data[[amt]], 0),
        # robust client label
        Cliente  = dplyr::coalesce(Parte, `Nombre del cliente`,
                                   as.character(`Código de cliente`), "(Sin nombre)"),
        `Días desde venc.` = as.integer(Sys.Date() - FechaEff)
      ) %>%
      dplyr::filter(Moneda == cur, FechaEff == sel_date)
    
    # robust client name for modal
    detail_raw <- detail_raw %>%
      dplyr::mutate(
        Cliente = dplyr::coalesce(
          dplyr::na_if(Parte, ""),
          dplyr::na_if(`Nombre del cliente`, ""),
          `Código de cliente`
        ),
        # guard against stray negatives (credit memos, parsing quirks):
        Importe = ifelse(is.na(Importe), 0, Importe),
        Importe = ifelse(Importe < 0, abs(Importe), Importe)
      )
    
    # Intercompany filter for detail list
    # Intercompany tri-state for AR detail modal
    mode_ar   <- input$interco_mode_ar %||% "exclude"
    ic        <- interco_settings()
    ar_codes  <- normalize_code(ic$ar_clients)
    if ("Código de cliente" %in% names(detail_raw)) {
      detail_raw <- apply_ic_filter(detail_raw, mode = mode_ar,
                                    code_col = "Código de cliente",
                                    ic_codes_norm = ar_codes)
    }
    
    
    if (nrow(detail_raw) == 0) {
      showModal(modalDialog(
        title = paste0("Sin cobros – ", format(sel_date, "%d-%m-%Y"), " – ", cur),
        "No hay cobros para este día.",
        easyClose = TRUE, footer = modalButton("Cerrar")
      ))
      return(invisible(NULL))
    }
    
    fmt_money <- function(x) paste0("$ ", scales::number(x, big.mark = ",", accuracy = 0.01))
    
    
    
    ## ================= INVOICE MODE ==============================================================
    ## ================= INVOICE MODE =================
    inv_col <- if ("Documento" %in% names(detail_raw)) "Documento" else guess_invoice_col(detail_raw)
    message("[AR] show_invoices_ar=", isTRUE(input$show_invoices_ar), #-----------inv_com 
            "  have_doc=", !is.null(inv_col) && inv_col %in% names(detail_raw))
    
    if (isTRUE(input$show_invoices_ar) && !is.null(inv_col) && inv_col %in% names(detail_raw)) {
      
      detail_tbl_inv <- detail_raw %>%
        dplyr::transmute(
          Empresa, Moneda, Documento,
          Factura  = Documento,
          Cliente  = Cliente,
          Importe,
          `Días desde venc.` = `Días desde venc.`
        ) %>%
        dplyr::arrange(dplyr::desc(Importe))
      
      showModal(modalDialog(
        title = paste0("Detalle de cobros – ", format(sel_date, "%d-%m-%Y"), " – ", cur, " • ", amt),
        size  = "l", easyClose = TRUE, footer = modalButton("Cerrar"),
        tagList(
          tags$div(
            style = "margin-bottom:8px;font-weight:600;",
            textOutput("sel_count_ar"),
            tags$br(),
            textOutput("sel_total_ar")
          ),
          DT::dataTableOutput("day_table_ar"),
          tags$div(
            style = "margin-top:10px; display:flex; gap:10px; align-items:end;",
            dateInput("move_to", "Mover a:", value = sel_date, weekstart = 1, language = "es"),
            actionButton("apply_move_ar_inv", "Mover", class = "btn btn-primary")
          )
        )
      ))
      
      local({
        dt  <- detail_tbl_inv
        fmt <- function(x) paste0("$ ", scales::number(x, big.mark = ",", accuracy = 0.01))
        
        output$day_table_ar <- DT::renderDataTable({
          DT::datatable(
            dt %>% dplyr::mutate(Importe = fmt(Importe)),
            selection = "multiple",
            rownames  = FALSE,
            options   = list(
              pageLength = 20,
              dom       = "ftip",
              scrollX   = TRUE,
              autoWidth = TRUE,
              order     = list(list(which(names(dt)=="Importe")-1, "desc")),
              columnDefs = list(list(className = "dt-right", targets = which(names(dt)=="Importe")-1))
            )
          )
        })
        
        output$sel_count_ar <- renderText("Seleccionados: 0")
        output$sel_total_ar <- renderText("Total seleccionado: $ 0")
        
        observeEvent(input$day_table_ar_rows_selected, {
          sel <- input$day_table_ar_rows_selected %||% integer(0)
          output$sel_count_ar <- renderText(paste0("Seleccionados: ", length(sel)))
          total <- if (length(sel)) sum(dt$Importe[sel], na.rm = TRUE) else 0
          output$sel_total_ar <- renderText(paste0("Total seleccionado: ", fmt(total)))
        }, ignoreInit = TRUE)
        
        observeEvent(input$apply_move_ar_inv, {
          sel <- input$day_table_ar_rows_selected %||% integer(0)
          if (!length(sel)) { showNotification("Selecciona al menos una factura.", type="warning"); return() }
          new_date <- as.Date(input$move_to)
          if (is.na(new_date)) { showNotification("Elige la nueva fecha.", type="warning"); return() }
          
          keys <- dt[sel, c("Empresa","Moneda","Documento")] %>% dplyr::distinct()
          apply_move_ar(keys, new_date)
          
          showNotification(paste0("Movidas ", nrow(keys), " factura(s)."), type="message")
          removeModal()
        }, ignoreInit = TRUE, once = TRUE)
      })
      
      return(invisible(NULL))
    }
    
    
    ## ================= GROUPED MODE (replicates invoice window) =================
    # Group by Empresa + Cliente, but keep a lookup to all underlying docs
    ## ================= GROUPED MODE (replicates invoice window) =================
    detail_tbl_grp <- detail_raw %>%
      dplyr::group_by(Empresa, Cliente) %>%
      dplyr::summarise(Importe = sum(Importe, na.rm = TRUE), .groups = "drop") %>%
      dplyr::arrange(dplyr::desc(Importe)) %>%
      dplyr::mutate(`Días desde venc.` = as.integer(Sys.Date() - sel_date))
    
    showModal(modalDialog(
      title = paste0("Detalle de cobros – ", format(sel_date, "%d-%m-%Y"), " – ", cur, " • ", amt),
      size  = "l", easyClose = TRUE, footer = modalButton("Cerrar"),
      tagList(
        tags$div(
          style = "margin-bottom:8px;font-weight:600;",
          textOutput("sel_count_ar"),
          tags$br(),
          textOutput("sel_total_ar")
        ),
        DT::dataTableOutput("day_table_ar"),
        tags$div(
          style = "margin-top:10px; display:flex; gap:10px; align-items:end;",
          dateInput("move_to", "Mover a:", value = sel_date, weekstart = 1, language = "es"),
          actionButton("apply_move_ar_grouped", "Mover", class = "btn btn-primary")
        )
      )
    ))
    
    local({
      dt  <- detail_tbl_grp
      fmt <- function(x) paste0("$ ", scales::number(x, big.mark = ",", accuracy = 0.01))
      
      # table with row selection
      output$day_table_ar <- DT::renderDataTable({
        DT::datatable(
          dt %>% dplyr::mutate(Importe = fmt(Importe)),
          selection = "multiple",
          rownames  = FALSE,
          options   = list(
            pageLength = 20,
            dom       = "ftip",
            scrollX   = TRUE,
            autoWidth = TRUE,
            order     = list(list(which(names(dt)=="Importe")-1, "desc")),
            columnDefs = list(list(className = "dt-right", targets = which(names(dt)=="Importe")-1))
          )
        )
      })
      
      # init counters
      output$sel_count_ar <- renderText("Seleccionados: 0")
      output$sel_total_ar <- renderText("Total seleccionado: $ 0")
      
      # live counters
      observeEvent(input$day_table_ar_rows_selected, {
        sel <- input$day_table_ar_rows_selected %||% integer(0)
        output$sel_count_ar <- renderText(paste0("Seleccionados: ", length(sel)))
        total <- if (length(sel)) sum(dt$Importe[sel], na.rm = TRUE) else 0
        output$sel_total_ar <- renderText(paste0("Total seleccionado: ", fmt(total)))
      }, ignoreInit = TRUE)
      
      # move all invoices behind the selected groups
      observeEvent(input$apply_move_ar_grouped, {
        sel <- input$day_table_ar_rows_selected %||% integer(0)
        if (!length(sel)) { showNotification("Selecciona al menos un cliente.", type="warning"); return() }
        new_date <- as.Date(input$move_to)
        if (is.na(new_date)) { showNotification("Elige la nueva fecha.", type="warning"); return() }
        
        # map selected (Empresa, Cliente) back to full rows of the clicked day
        selected_pairs <- dt[sel, c("Empresa","Cliente")]
        if (!"Documento" %in% names(detail_raw)) {
          showNotification("No se encontró la columna 'Documento'.", type = "error"); return()
        }
        docs_to_move <- detail_raw %>%
          dplyr::semi_join(selected_pairs, by = c("Empresa","Cliente")) %>%
          dplyr::filter(!is.na(Documento)) %>%
          dplyr::distinct(Empresa, Moneda, Documento)
        
        if (!nrow(docs_to_move)) {
          showNotification("No se encontraron facturas para mover.", type="warning"); return()
        }
        
        apply_move_ar(docs_to_move, new_date)
        showNotification(paste0("Movidas ", nrow(docs_to_move), " factura(s)."), type="message")
        removeModal()
      }, ignoreInit = TRUE, once = TRUE)
    })
    
    
  })
  
  #=======================================================================================================
  #=================================================================  AP  ==================================================================================
  #=======================================================================================================
  
  # --- AP state ---
  files_selected_ap     <- reactiveVal(candidate_files_ap)
  tables_by_company_ap  <- reactiveVal(NULL)
  df_raw_multi_ap       <- reactiveVal(NULL)
  moves_db_ap           <- reactiveVal(load_moves_ap())   # or load_moves() if you share one DB
  rv_ap <- reactiveValues(day_map = NULL, day_date = NULL)
  
  #-------------------------------------------------------
  
  # ---- AP: calendar plot ----
  output$cal_ap <- renderPlot({
    req(df_due_multi_ap(), input$cur_ap, input$month_ap)
    mstart <- lubridate::floor_date(as.Date(input$month_ap), "month")
    
    calendar_plot(
      df_due_multi_ap(),
      month_start  = mstart,
      currency     = input$cur_ap,
      max_lines    = 2,
      title_prefix = "Pagos programados"
    )
  })#----------------------------------------------------------------
  
  # --------------- AP helper: apply a move; if new_date == original, clear the move instead of upserting --------
  # --- AP helper: apply a move; if new_date == original, clear the move instead of upserting
  apply_move_ap <- function(selected_keys, new_date) {
    # selected_keys must have: Empresa, Moneda, Documento
    df <- df_raw_multi_ap()
    db <- moves_db_ap()
    
    # Map each doc to its original date
    orig_map <- df %>%
      dplyr::select(Empresa, Moneda, Documento, FechaVenc_Original) %>%
      dplyr::distinct()
    
    keys <- selected_keys %>%
      dplyr::distinct(Empresa, Moneda, Documento) %>%
      dplyr::left_join(orig_map, by = c("Empresa","Moneda","Documento")) %>%
      dplyr::mutate(
        FechaVenc_Proyectada = as.Date(new_date),
        last_updated         = Sys.time()
      )
    
    # Split into: clear (revert to original) vs upsert (projected != original)
    to_clear  <- keys %>% dplyr::filter(FechaVenc_Proyectada == FechaVenc_Original)
    to_upsert <- keys %>% dplyr::filter(FechaVenc_Proyectada != FechaVenc_Original)
    
    # ---- Persist DB ----
    if (nrow(to_clear)) {
      db <- dplyr::anti_join(
        db,
        to_clear %>% dplyr::select(Empresa, Moneda, Documento),
        by = c("Empresa","Moneda","Documento")
      )
    }
    if (nrow(to_upsert)) {
      stopifnot(exists("upsert_moves", mode = "function"))
      db <- upsert_moves(
        db,
        to_upsert %>% dplyr::select(Empresa, Moneda, Documento, FechaVenc_Proyectada, last_updated)
      )
    }
    
    moves_db_ap(db)
    if (exists("save_moves_ap", mode = "function")) save_moves_ap(db) else save_moves(db)
    
    # ---- Update in-memory df so UI refreshes immediately ----
    idx_for <- function(keys_df) {
      if (!nrow(keys_df)) return(integer(0))
      dplyr::inner_join(
        df %>% dplyr::mutate(.idx = dplyr::row_number()) %>%
          dplyr::select(.idx, Empresa, Moneda, Documento),
        keys_df %>% dplyr::select(Empresa, Moneda, Documento),
        by = c("Empresa","Moneda","Documento")
      )$.idx
    }
    
    i_clear  <- idx_for(to_clear)
    i_upsert <- idx_for(to_upsert)
    
    if (length(i_clear)) {
      df$FechaVenc_Proyectada[i_clear] <- as.Date(NA)
      df$FechaEff[i_clear]             <- df$FechaVenc_Original[i_clear]
    }
    if (length(i_upsert)) {
      df$FechaVenc_Proyectada[i_upsert] <- as.Date(new_date)
      df$FechaEff[i_upsert]             <- as.Date(new_date)
    }
    
    df_raw_multi_ap(df)
  }
  #---------------------------------------------------------------------------
  
  # ---- AP: build day x vendor table (reactive) ----
  df_due_multi_ap <- reactive({
    d <- req(df_raw_multi_ap())
    
    # Ensure vendor name column exists and is filled down
    if (!"Parte" %in% names(d)) {
      d <- standardize_party_ap(d)  # your robust version
    }
    
    amt <- input$amount_kind_ap %||% "Saldo vencido"  # or "Abono futuro"
    validate(need(amt %in% names(d), paste("No encuentro la columna:", amt)))
    
    d %>%
      dplyr::mutate(
        Importe = tidyr::replace_na(.data[[amt]], 0),
        Fecha   = as.Date(FechaEff),
        Moneda  = toupper(trimws(Moneda))
      ) %>%
      dplyr::filter(!is.na(Fecha)) %>%
      dplyr::group_by(Fecha, Moneda, Parte) %>%
      dplyr::summarise(Importe = sum(Importe, na.rm = TRUE), .groups = "drop")
  })
  
  
  # AP: pick/unpick files -----------------------------------------------------------------------
  observeEvent(input$files_pick_ap, {
    files_selected_ap(input$files_pick_ap %||% character(0))
  }, ignoreInit = TRUE)
  
  # AP: add uploaded files ------------------------------------------------------------------------
  observeEvent(input$more_files_ap, {
    df <- req(input$more_files_ap)        # data.frame with $name, $datapath, $type, $size
    new_paths  <- normalizePath(df$datapath, winslash = "/", mustWork = FALSE)
    new_labels <- df$name                  # <-- real filenames to show
    
    # Update the label map (path -> display name), keeping any existing labels
    lbl_map <- files_labels_ap()
    lbl_map[new_paths] <- new_labels
    files_labels_ap(lbl_map)
    
    # Merge with whatever was already selected
    new_all <- unique(c(files_selected_ap(), new_paths))
    files_selected_ap(new_all)
    
    # Build named choices: values = paths, names = display labels
    choices <- new_all
    names(choices) <- lbl_map[choices]
    
    updateCheckboxGroupInput(
      session, "files_pick_ap",
      choices  = choices,
      selected = new_all
    )
  }, ignoreInit = TRUE) #------------------------------------------------------------
  
  
  #======================================================= Process files, but for Acc Payable AP
  observeEvent(input$process_files_ap, {
    tryCatch({
      paths <- files_selected_ap()
      validate(need(length(paths) > 0, "Selecciona al menos un archivo (CxP)"))
      
      tabs <- process_pagar_files(paths)
      if (!length(tabs) || !all(vapply(tabs, is.data.frame, logical(1)))) {
        stop("No se pudo leer ningún archivo válido (CxP).")
      }
      tables_by_company_ap(tabs)
      
      combined_df <- dplyr::bind_rows(tabs, .id = "Tabla") %>%
        standardize_party_ap() %>%          # ensure Parte from “Nombre de acreedor”
        # standardize_codigo_ap() %>%       # requires helper (optional)
        add_documento() %>%
        dplyr::mutate(
          Moneda  = toupper(trimws(Moneda)),
          `Fecha de vencimiento` = as.Date(`Fecha de vencimiento`),
          FechaVenc_Original     = `Fecha de vencimiento`
        ) %>%
        dedupe_invoices() %>%
        dplyr::left_join(moves_db_ap(), by = c("Empresa","Moneda","Documento")) %>%
        dplyr::mutate(
          FechaVenc_Proyectada = as.Date(FechaVenc_Proyectada),
          FechaEff             = dplyr::coalesce(FechaVenc_Proyectada, FechaVenc_Original),
          .row_id              = dplyr::row_number()
        )
      
      
      message("AP combined_df rows: ", nrow(combined_df))
      df_raw_multi_ap(combined_df)
      
      output$currency_ui_ap <- renderUI({
        selectInput("cur_ap", "Moneda", choices = sort(unique(combined_df$Moneda)))
      })
    }, error = function(e) {
      showModal(modalDialog(title = "Error al procesar (CxP)", paste(conditionMessage(e)), easyClose = TRUE))
    })
  }, ignoreInit = TRUE)
  #----------------------------------------------------------------------------
  
  #=======================================================================================================================================================================================
  #===================================================================== AP click Handler =================================================================================================
  #=======================================================================================================================================================================================
  # ---- AP: click on a day to open invoice/vendor details ----
  observeEvent(input$cal_click_ap, {
    d_raw <- req(df_raw_multi_ap())
    cur   <- toupper(trimws(input$cur_ap))
    amt   <- input$amount_kind_ap %||% "Saldo vencido"
    
    # Map click -> date
    wday_clicked <- round(input$cal_click_ap$x)
    week_clicked <- round(input$cal_click_ap$y)
    if (is.na(wday_clicked) || is.na(week_clicked)) return(NULL)
    
    mstart  <- lubridate::floor_date(as.Date(input$month_ap), "month")
    grid    <- calendar_grid(mstart)
    day_row <- dplyr::filter(grid, wday == !!wday_clicked, week == !!week_clicked)
    if (nrow(day_row) != 1) return(NULL)
    sel_date <- day_row$Fecha[[1]]
    
    # Base rows for that day/currency
    detail_raw <- d_raw %>%
      dplyr::mutate(
        FechaEff = as.Date(FechaEff),
        Moneda   = toupper(trimws(Moneda)),
        Importe  = tidyr::replace_na(.data[[amt]], 0),
        # robust vendor label (prefer name, fall back to code)
        Proveedor = dplyr::coalesce(
          dplyr::na_if(Parte, ""),
          dplyr::na_if(`Nombre de acreedor`, ""),
          `Código de proveedor`
        ),
        # days since original due date if present, else since effective date
        `Días desde venc.` = {
          base <- if ("Fecha de vencimiento" %in% names(.)) as.Date(.$`Fecha de vencimiento`) else FechaEff
          as.integer(Sys.Date() - base)
        }
      ) %>%
      dplyr::filter(Moneda == cur, FechaEff == sel_date) %>%
      dplyr::mutate(
        # guard against negatives from credits/parsing:
        Importe = ifelse(is.na(Importe), 0, Importe),
        Importe = ifelse(Importe < 0, abs(Importe), Importe)
      )
    
    # Intercompany tri-state filter for the modal (matches your calendar filter)
    mode_ap  <- input$interco_mode_ap %||% "exclude"
    ic       <- interco_settings()
    ap_codes <- normalize_code(ic$ap_suppliers)
    if ("Código de proveedor" %in% names(detail_raw)) {
      detail_raw <- apply_ic_filter(detail_raw,
                                    mode = mode_ap,
                                    code_col = "Código de proveedor",
                                    ic_codes_norm = ap_codes)
    }
    
    # Empty day guard
    if (nrow(detail_raw) == 0) {
      showModal(modalDialog(
        title = paste0("Sin pagos – ", format(sel_date, "%d-%m-%Y"), " – ", cur),
        "No hay pagos para este día.",
        easyClose = TRUE, footer = modalButton("Cerrar")
      ))
      return(invisible(NULL))
    }
    
    # Decide invoice id column
    inv_col <- if ("Documento" %in% names(detail_raw)) "Documento" else guess_invoice_col(detail_raw)
    
    ## ================= INVOICE MODE =================
    if (isTRUE(input$show_invoices_ap) && !is.null(inv_col) && inv_col %in% names(detail_raw)) {
      detail_tbl_inv <- detail_raw %>%
        dplyr::transmute(
          Empresa, Moneda, Documento = .data[[inv_col]],
          Factura   = .data[[inv_col]],
          Proveedor = Proveedor,
          Importe,
          `Días desde venc.` = `Días desde venc.`
        ) %>%
        dplyr::arrange(dplyr::desc(Importe))
      
      showModal(modalDialog(
        title = paste0("Detalle de pagos – ", format(sel_date, "%d-%m-%Y"), " – ", cur, " • ", amt),
        size  = "l", easyClose = TRUE, footer = modalButton("Cerrar"),
        tagList(
          tags$div(
            style = "margin-bottom:8px;font-weight:600;",
            textOutput("sel_count_ap"),
            tags$br(),
            textOutput("sel_total_ap")
          ),
          DT::dataTableOutput("day_table_ap"),
          tags$div(
            style = "margin-top:10px; display:flex; gap:10px; align-items:end;",
            dateInput("move_to_ap", "Mover a:", value = sel_date, weekstart = 1, language = "es"),
            actionButton("apply_move_ap_inv", "Mover", class = "btn btn-primary")
          )
        )
      ))
      
      # Snapshot everything for THIS modal & avoid observer stacking
      local({
        dt    <- detail_tbl_inv
        date0 <- sel_date
        
        output$day_table_ap <- DT::renderDataTable({
          DT::datatable(
            dt %>% dplyr::mutate(Importe = fmt_money(Importe)),
            selection = "multiple",
            rownames  = FALSE,
            options   = list(
              pageLength = 20,
              dom       = "ftip",
              scrollX   = TRUE,
              autoWidth = TRUE,
              order     = list(list(which(names(dt)=="Importe")-1, "desc")),
              columnDefs = list(list(className = "dt-right", targets = which(names(dt)=="Importe")-1))
            )
          )
        })
        
        # Kill previous observers (if any), then create fresh ones bound to this modal
        if (!is.null(rv_ap$sel_obs))  rv_ap$sel_obs$destroy()
        if (!is.null(rv_ap$move_obs)) rv_ap$move_obs$destroy()
        
        rv_ap$sel_obs <- observeEvent(input$day_table_ap_rows_selected, {
          sel <- input$day_table_ap_rows_selected %||% integer(0)
          output$sel_count_ap <- renderText(paste0("Seleccionados: ", length(sel)))
          output$sel_total_ap <- renderText(paste0("Total seleccionado: ", fmt_money(sum(dt$Importe[sel], na.rm = TRUE))))
        }, ignoreInit = TRUE)
        
        rv_ap$move_obs <- observeEvent(input$apply_move_ap_inv, {
          sel <- input$day_table_ap_rows_selected %||% integer(0)
          if (!length(sel)) { showNotification("Selecciona al menos una factura.", type = "warning"); return(invisible(NULL)) }
          new_date <- as.Date(input$move_to_ap)
          if (is.na(new_date)) { showNotification("Elige la nueva fecha.", type = "warning"); return(invisible(NULL)) }
          
          keys <- dt[sel, c("Empresa","Moneda","Documento")] %>% dplyr::distinct()
          apply_move_ap(keys, new_date)
          
          showNotification(
            paste0("Movidas ", nrow(keys), " factura(s) a ", format(new_date, "%d-%m-%Y")),
            type = "message"
          )
          removeModal()
        }, ignoreInit = TRUE, once = TRUE)
      })
      
      return(invisible(NULL))
    }
    
    ## ================= GROUPED MODE =================
    detail_tbl_grp <- detail_raw %>%
      dplyr::group_by(Empresa, Proveedor) %>%
      dplyr::summarise(Importe = sum(Importe, na.rm = TRUE), .groups = "drop") %>%
      dplyr::arrange(dplyr::desc(Importe)) %>%
      dplyr::mutate(`Días desde venc.` = as.integer(Sys.Date() - sel_date))
    
    showModal(modalDialog(
      title = paste0("Detalle de pagos – ", format(sel_date, "%d-%m-%Y"), " – ", cur, " • ", amt),
      size  = "l", easyClose = TRUE, footer = modalButton("Cerrar"),
      tagList(
        tags$div(
          style = "margin-bottom:8px;font-weight:600;",
          textOutput("sel_count_ap"),
          tags$br(),
          textOutput("sel_total_ap")
        ),
        DT::dataTableOutput("day_table_ap"),
        tags$div(
          style = "margin-top:10px; display:flex; gap:10px; align-items:end;",
          dateInput("move_to_ap", "Mover a:", value = sel_date, weekstart = 1, language = "es"),
          actionButton("apply_move_ap_grouped", "Mover", class = "btn btn-primary")
        )
      )
    ))
    
    local({
      dt_grp <- detail_tbl_grp
      date0  <- sel_date
      
      output$day_table_ap <- DT::renderDataTable({
        DT::datatable(
          dt_grp %>% dplyr::mutate(Importe = fmt_money(Importe)),
          selection = "multiple",
          rownames  = FALSE,
          options   = list(
            pageLength = 20,
            dom       = "ftip",
            scrollX   = TRUE,
            autoWidth = TRUE,
            order     = list(list(which(names(dt_grp)=="Importe")-1, "desc")),
            columnDefs = list(list(className = "dt-right", targets = which(names(dt_grp)=="Importe")-1))
          )
        )
      })
      
      if (!is.null(rv_ap$sel_obs))  rv_ap$sel_obs$destroy()
      if (!is.null(rv_ap$move_obs)) rv_ap$move_obs$destroy()
      
      rv_ap$sel_obs <- observeEvent(input$day_table_ap_rows_selected, {
        sel <- input$day_table_ap_rows_selected %||% integer(0)
        output$sel_count_ap <- renderText(paste0("Seleccionados: ", length(sel)))
        output$sel_total_ap <- renderText(paste0("Total seleccionado: ", fmt_money(sum(dt_grp$Importe[sel], na.rm = TRUE))))
      }, ignoreInit = TRUE)
      
      rv_ap$move_obs <- observeEvent(input$apply_move_ap_grouped, {
        sel <- input$day_table_ap_rows_selected %||% integer(0)
        if (!length(sel)) { showNotification("Selecciona al menos un proveedor.", type = "warning"); return(invisible(NULL)) }
        new_date <- as.Date(input$move_to_ap)
        if (is.na(new_date)) { showNotification("Elige la nueva fecha.", type = "warning"); return(invisible(NULL)) }
        
        if (is.null(inv_col) || !inv_col %in% names(detail_raw)) {
          showNotification("No se encontró la columna 'Documento' para identificar facturas.", type = "error")
          return(invisible(NULL))
        }
        
        selected_pairs <- dt_grp[sel, c("Empresa","Proveedor")]
        docs_to_move <- detail_raw %>%
          dplyr::semi_join(selected_pairs, by = c("Empresa" = "Empresa", "Proveedor" = "Proveedor")) %>%
          dplyr::filter(!is.na(.data[[inv_col]])) %>%
          dplyr::transmute(Empresa, Moneda, Documento = .data[[inv_col]]) %>%
          dplyr::distinct()
        
        if (!nrow(docs_to_move)) {
          showNotification("No se encontraron facturas para mover.", type = "warning")
          return(invisible(NULL))
        }
        
        apply_move_ap(docs_to_move, new_date)
        
        showNotification(
          paste0("Movidas ", nrow(docs_to_move), " factura(s) a ", format(new_date, "%d-%m-%Y")),
          type = "message"
        )
        removeModal()
      }, ignoreInit = TRUE, once = TRUE)
    })
  })
  
  
  
  
  
}



shinyApp(ui, server)




# --- (Optional) save cleaned data for analysis ---
# readr::write_csv(df, "antiguedad_crossdocking_clean.csv")
# saveRDS(df, "antiguedad_crossdocking_clean.rds")


