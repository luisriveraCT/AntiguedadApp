
#TO SELECT THE SOURCE AND OUTPUT FOLDERS CHANGE DATA_DIR FOR SOURCE AND DATA_TARGET FOR OUTPUT.

# ======================================================================
# build_data.R — Production ETL Pipeline for Antiguedad App
# ======================================================================

suppressPackageStartupMessages({
  library(readxl)
  library(dplyr)
  library(stringr)
  library(lubridate)
  library(purrr)
  library(tibble)
  library(tidyr)
  library(aws.s3)
})

# null-coalesce infix used across helpers and server
`%||%` <- function(x, y) {
  if (is.null(x)) return(y)
  if (length(x) == 0L) return(y)
  if (length(x) == 1L && is.na(x)) return(y)
  x
}
#-----------------------------------------------------------------

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
#---------------------------- Turn values into currency.
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


# Ensure we have a Moneda column with reasonable defaults
ensure_moneda <- function(df) {
  cur_guess <- names(df)[stringr::str_detect(
    tolower(names(df)),
    "moneda|currency|divisa|balance due \\(currency\\)|balance due \\(lc\\)"
  )]
  
  if (length(cur_guess) >= 1) {
    df <- dplyr::rename(df, Moneda = !!cur_guess[1])
  } else if (!"Moneda" %in% names(df)) {
    df$Moneda <- "MXN"
  }
  
  df %>%
    dplyr::mutate(Moneda = toupper(trimws(as.character(Moneda)))) %>%
    tidyr::fill(Moneda, .direction = "down")
}

# ---------------------------------------------------------
# Project paths
# ---------------------------------------------------------
#C:/Users/luisr/Documents/Proyectos de Integracion/BackupApp/Exceles para la app build_data
DATA_DIR <- "data"
#data
FAST_AR <- file.path(DATA_DIR, "clientes_daily.rds")
FAST_AP <- file.path(DATA_DIR, "proveedores_daily.rds")

COMPANY_MAP <- c(
  "NG"  = "Networks Group",
  "NTS" = "Networks Trucking Services",
  "NCS" = "Networks Crossdocking Services",
  "NL"  = "Networks & Logistics",
  "NRS" = "Networks Realtors"
)

# ---------------------------------------------------------
# Detect all Excel files in data/
# ---------------------------------------------------------
list_antiguedad_files <- function(dir = DATA_DIR) {
  files <- list.files(
    dir,
    pattern = "(?i)^(clientes|proveedores)_[A-Za-z0-9]+\\.xlsx$",
    full.names = TRUE
  )
  files[!grepl("^~\\$", basename(files))]
}

# ---------------------------------------------------------
# Parse new filename structure
# clientes_NG.xlsx → ledger=AR, initials=NG
# proveedores_NTS.xlsx → ledger=AP
# ---------------------------------------------------------
parse_filename_meta <- function(path, display_name = NULL) {
  fn <- tools::file_path_sans_ext(basename(display_name %||% path))
  
  m <- str_match(
    fn,
    "(?i)^(clientes|proveedores)_([A-Za-z0-9]+)$"
  )
  
  if (all(is.na(m))) {
    warning("Cannot parse filename: ", fn)
    return(list(ledger=NA, initials=NA, company=NA))
  }
  
  kind     <- tolower(m[,2])  # clientes / proveedores
  initials <- toupper(m[,3])  # NG / NCS / NRS...
  
  ledger <- case_when(
    kind == "clientes"    ~ "AR",
    kind == "proveedores" ~ "AP",
    TRUE ~ NA_character_
  )
  
  company <- if (initials %in% names(COMPANY_MAP)) COMPANY_MAP[[initials]] else initials
  
  list(ledger=ledger, initials=initials, company=company)
}

# ---------------------------------------------------------
# Partition file list into AR, AP, unknown
# ---------------------------------------------------------
split_paths_by_ledger <- function(paths) {
  meta <- lapply(paths, parse_filename_meta)
  ledger <- vapply(meta, `[[`, character(1), "ledger")
  
  list(
    ar = paths[ledger == "AR" & !is.na(ledger)],
    ap = paths[ledger == "AP" & !is.na(ledger)],
    unknown = paths[is.na(ledger)]
  )
}

# ---------------------------------------------------------
# SAP date cleaning
# ---------------------------------------------------------
parse_sap_date <- function(x) {
  if (inherits(x, "Date")) return(x)
  
  xc <- as.character(x)
  num <- suppressWarnings(as.numeric(xc))
  out <- as.Date(rep(NA_real_, length(xc)))
  
  # numeric Excel serials
  is_num <- !is.na(num)
  if (any(is_num)) {
    d1900 <- as.Date(num[is_num], origin="1899-12-30")
    bad   <- d1900 < as.Date("1900-01-01") | d1900 > as.Date("2100-01-01")
    d1904 <- as.Date(num[is_num][bad], origin="1904-01-01")
    d1900[bad] <- d1904
    out[is_num] <- d1900
  }
  
  if (any(!is_num)) {
    xs <- gsub("\\.", "/", xc[!is_num])
    d1 <- suppressWarnings(dmy(xs))
    d2 <- suppressWarnings(ymd(xs))
    out[!is_num] <- ifelse(!is.na(d1), d1, d2)
  }
  
  out
}

# ---------------------------------------------------------
# Convert currencies like "1,234.56" or "1.234,56"
# ---------------------------------------------------------
to_currency_num <- function(x) {
  if (is.numeric(x)) return(x)
  
  x2 <- str_replace_all(x, "[^0-9,.-]", "")
  uses_comma_decimal <- any(str_detect(x2, ",\\d{1,2}$"), na.rm=TRUE)
  
  if (uses_comma_decimal) {
    x2 <- str_replace_all(x2, "\\.", "")
    x2 <- str_replace(x2, ",", ".")
  } else {
    x2 <- str_replace_all(x2, ",", "")
  }
  
  suppressWarnings(as.numeric(x2))
}

# ---------------------------------------------------------
# Standardize AR (clientes)
# ---------------------------------------------------------
# =====================================================================
# CLEAN + STANDARDIZE ACCOUNTS RECEIVABLE (CLIENTES)
# Symmetric to read_clean_pagar()
# =====================================================================

read_clean_ar <- function(path) {
  message("Reading AR file: ", basename(path))
  meta <- parse_filename_meta(path)
  
  # ---- 1) Read raw Excel as TEXT ------------------------------------
  df <- suppressWarnings(
    readxl::read_excel(path, col_types = "text")
  )
  if (!nrow(df)) return(NULL)
  
  # ---- 2) CURRENCY (EXACT SAME LOGIC AS AP) -------------------------
  # SAP provides one currency value per invoice via *(moneda)* columns
  
  if ("Saldo vencido (moneda)" %in% names(df)) {
    df$Moneda <- trimws(df[["Saldo vencido (moneda)"]])
    
  } else if ("Abono futuro (moneda)" %in% names(df)) {
    df$Moneda <- trimws(df[["Abono futuro (moneda)"]])
    
  } else {
    stop("AR error: no '(moneda)' column found for currency.")
  }
  
  df$Moneda <- toupper(as.character(df$Moneda))
  
  # ---- 3) CLIENT NAME / CODE (HEADER ROWS DRIVE FILL-DOWN) ----------
  name_col <- dplyr::case_when(
    "Nombre del cliente" %in% names(df) ~ "Nombre del cliente",
    TRUE                                ~ NA_character_
  )
  
  code_col <- dplyr::case_when(
    "Código de cliente" %in% names(df) ~ "Código de cliente",
    TRUE                               ~ NA_character_
  )
  
  # Canonical fields
  if (!"Parte" %in% names(df)) df$Parte <- NA_character_
  if (!"Código de cliente" %in% names(df)) df$`Código de cliente` <- NA_character_
  
  # Inject header values
  if (!is.na(name_col)) df$Parte <- df[[name_col]]
  if (!is.na(code_col)) df$`Código de cliente` <- df[[code_col]]
  
  # Fill-down BEFORE removing headers
  df <- df %>%
    tidyr::fill(Parte, `Código de cliente`, .direction = "down")
  
  df$Parte <- trimws(df$Parte)
  df$`Código de cliente` <- trimws(df$`Código de cliente`)
  
  # ---- 4) DOCUMENTO → REMOVE HEADERS --------------------------------
  doc_col <- dplyr::case_when(
    "Nº documento" %in% names(df) ~ "Nº documento",
    "Document" %in% names(df)     ~ "Document",
    TRUE                          ~ NA_character_
  )
  
  if (is.na(doc_col))
    stop("AR error: Documento column not found.")
  
  df$Documento <- trimws(as.character(df[[doc_col]]))
  df$Documento[df$Documento == ""] <- NA_character_
  
  # Remove header / total rows
  df <- df[!is.na(df$Documento), , drop = FALSE]
  
  # ---- 5) DATE CLEANING ---------------------------------------------
  date_cols <- intersect(
    names(df),
    c("Fecha de contabilización", "Fecha de vencimiento", "Due Date")
  )
  if (length(date_cols)) {
    df[date_cols] <- lapply(df[date_cols], parse_sap_date)
  }
  
  if (!"Fecha de vencimiento" %in% names(df) && "Due Date" %in% names(df)) {
    df$`Fecha de vencimiento` <- df[["Due Date"]]
  }
  
  # ---- 6) NUMERIC AMOUNTS -------------------------------------------
  num_cols <- grep(
    "(saldo|abono|\\d+\\s*-\\s*\\d+|121\\+)",
    names(df),
    ignore.case = TRUE,
    value = TRUE
  )
  
  if (length(num_cols)) {
    df[num_cols] <- lapply(df[num_cols], to_currency_num)
  }
  
  # ---- 7) METADATA --------------------------------------------------
  df$Empresa      <- meta$company
  df$Archivo      <- basename(path)
  df$FechaArchivo <- Sys.Date()
  df$ArchivoMtime <- file.mtime(path)
  df$Tipo         <- "AR"
  
  df
}



# ---------------------------------------------------------
# Standardize AP (proveedores)
# ---------------------------------------------------------

# ==========================================================
# AP ETL — clean proveedores_* Excel into a unified schema
# - Uses header rows (Vendor Code / Vendor Name) to fill down
# - Drops header/empty rows (no Documento)
# - Keeps per-invoice currency in Moneda (MXN / USD / etc.)
# ==========================================================
read_clean_ap <- function(path) {
  message("Reading AP file: ", basename(path))
  meta <- parse_filename_meta(path)
  
  # ---- 1) Read raw Excel as text -----------------------------------------
  df <- suppressWarnings(
    readxl::read_excel(path, col_types = "text")
  )
  if (!nrow(df)) return(NULL)
  
  # ---- 2) CURRENCY (SAP provides one value per invoice) -------------------
  # Use EXACTLY the SAP field, do not parse, do not convert prematurely.
  
  if ("Balance Due (currency)" %in% names(df)) {
    df$Moneda <- trimws(df[["Balance Due (currency)"]])
    
  } else if ("Saldo vencido (moneda)" %in% names(df)) {
    df$Moneda <- trimws(df[["Saldo vencido (moneda)"]])
    
  } else {
    df$Moneda <- NA_character_
  }
  
  # Standardize case only (does NOT break values)
  df$Moneda <- toupper(as.character(df$Moneda))
  
  
  # ---- 3) Vendor NAME / CODE (drive fill-down) ---------------------------
  name_col <- dplyr::case_when(
    "Vendor Name" %in% names(df)        ~ "Vendor Name",
    "Nombre de acreedor" %in% names(df) ~ "Nombre de acreedor",
    TRUE                                ~ NA_character_
  )
  
  code_col <- dplyr::case_when(
    "Vendor Code" %in% names(df)         ~ "Vendor Code",
    "Código de proveedor" %in% names(df) ~ "Código de proveedor",
    TRUE                                 ~ NA_character_
  )
  
  # Canonical fields
  if (!"Parte" %in% names(df)) df$Parte <- NA_character_
  if (!"Código de proveedor" %in% names(df))
    df$`Código de proveedor` <- NA_character_
  
  # Inject raw values (headers only)
  if (!is.na(name_col)) df$Parte <- df[[name_col]]
  if (!is.na(code_col)) df$`Código de proveedor` <- df[[code_col]]
  
  # Fill-down BEFORE removing headers
  df <- df %>%
    tidyr::fill(Parte, `Código de proveedor`, .direction = "down")
  
  df$Parte <- trimws(df$Parte)
  df$`Código de proveedor` <- trimws(df$`Código de proveedor`)
  
  
  # ---- 4) Normalize numeric columns (safe conversions) -------------------
  # Map English → Spanish canonical names
  if ("Balance Due" %in% names(df) && !"Saldo vencido" %in% names(df))
    df$`Saldo vencido` <- df[["Balance Due"]]
  
  if ("Future Remit" %in% names(df) && !"Abono futuro" %in% names(df))
    df$`Abono futuro` <- df[["Future Remit"]]
  
  if ("Balance Due (currency)" %in% names(df) &&
      !"Saldo vencido (moneda)" %in% names(df))
    df$`Saldo vencido (moneda)` <- df[["Balance Due (currency)"]]
  
  if ("Future Remit (currency)" %in% names(df) &&
      !"Abono futuro (moneda)" %in% names(df))
    df$`Abono futuro (moneda)` <- df[["Future Remit (currency)"]]
  
  # Aging bucket currency naming
  df <- df %>%
    dplyr::rename_with(
      ~ sub("\\(currency\\)", "(moneda)", .x, ignore.case = TRUE),
      .cols = dplyr::matches("\\(currency\\)", ignore.case = TRUE)
    )
  
  
  # ---- 5) Dates including posting date (A3) -------------------------------
  date_cols <- intersect(
    names(df),
    c("Posting Date", "Fecha de contabilización", "Due Date", "Fecha de vencimiento")
  )
  
  if (length(date_cols)) {
    df[date_cols] <- lapply(df[date_cols], parse_sap_date)
  }
  
  # Canonical vencimiento
  if (!"Fecha de vencimiento" %in% names(df) && "Due Date" %in% names(df)) {
    df$`Fecha de vencimiento` <- df[["Due Date"]]
  }
  
  
  # ---- 6) Convert numeric amounts ----------------------------------------
  num_cols <- grep(
    "(saldo|abono|balance|remit|\\d+\\s*-\\s*\\d+|121\\+)",
    names(df),
    ignore.case = TRUE,
    value = TRUE
  )
  
  if (length(num_cols)) {
    df[num_cols] <- lapply(df[num_cols], to_currency_num)
  }
  
  
  # ---- 7) Document number → remove headers (A4) ---------------------------
  doc_col <- dplyr::case_when(
    "Doc. No." %in% names(df)      ~ "Doc. No.",
    "Document" %in% names(df)      ~ "Document",
    "Nº documento" %in% names(df)  ~ "Nº documento",
    TRUE                           ~ NA_character_
  )
  
  df$Documento <- trimws(as.character(df[[doc_col]]))
  df$Documento[df$Documento == ""] <- NA_character_
  
  # Remove non-invoice rows (headers)
  df <- df[!is.na(df$Documento), , drop = FALSE]
  
  
  # ---- 8) Metadata --------------------------------------------------------
  df$Empresa      <- meta$company
  df$Archivo      <- basename(path)
  df$FechaArchivo <- Sys.Date()
  df$ArchivoMtime <- file.mtime(path)
  
  df
}






# ---------------------------------------------------------
# Generic loader (AR or AP)
# ---------------------------------------------------------
read_goods <- function(paths) {
  if (!length(paths)) return(tibble())
  out <- lapply(paths, function(p) {
    meta <- parse_filename_meta(p)
    tryCatch({
      if (meta$ledger == "AR") {
        read_clean_ar(p)
      } else if (meta$ledger == "AP") {
        read_clean_ap(p)
      } else {
        warning("Unknown ledger: ", p)
        NULL
      }
    }, error = function(e) {
      warning("Error reading ", basename(p), ": ", e$message)
      NULL
    })
  })
  
  bind_rows(Filter(Negate(is.null), out))
}

# ======================================================================
# MAIN EXECUTION — BUILD RDS FILES
# ======================================================================

message("Searching for Excel files in: ", DATA_DIR)

files <- list_antiguedad_files(DATA_DIR)
split <- split_paths_by_ledger(files)

message("AR files: ", length(split$ar))
message("AP files: ", length(split$ap))
message("Unknown files: ", length(split$unknown))

message("Processing AR...")
ar_data <- read_goods(split$ar)

message("Processing AP...")
ap_data <- read_goods(split$ap)

message("Saving RDS files...")
saveRDS(ar_data, FAST_AR)
saveRDS(ap_data, FAST_AP)

message("DONE! RDS written:")
message("  - ", FAST_AR)
message("  - ", FAST_AP)

#=======================================================================
#  AMAZON AWS S3 DATABASE UPLOAD
#=======================================================================

S3_BUCKET <- "antiguedad-rds-prod"

message("Uploading RDS files to S3...")

put_object(
  file = FAST_AR,
  object = "clientes_daily.rds",
  bucket = S3_BUCKET
)

put_object(
  file = FAST_AP,
  object = "proveedores_daily.rds",
  bucket = S3_BUCKET
)

message("S3 upload complete.")

bucket <- Sys.getenv("S3_BUCKET")

aws.s3::s3saveRDS(
  object = clientes_daily,
  bucket = bucket,
  object = "clientes_daily.rds"
)

aws.s3::s3saveRDS(
  object = proveedores_daily,
  bucket = bucket,
  object = "proveedores_daily.rds"
)

message("✅ RDS files uploaded to S3")


