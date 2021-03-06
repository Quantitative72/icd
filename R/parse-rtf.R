# Copyright (C) 2014 - 2017  Jack O. Wasey
#
# This file is part of icd.
#
# icd is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# icd is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with icd. If not, see <http:#www.gnu.org/licenses/>.

# try parsing the RTF, and therefore get subheadings, as well as billable codes.
# ftp://ftp.cdc.gov/pub/Health_Statistics/NCHS/Publications/ICD9-CM/2011/
#
# see https://github.com/LucaFoschini/ICD-9_Codes for a completely different
# approach in python

#' Fetch RTF for a given year
#'
#' Will return NULL if offline and not available
#' @param year character vector of length one, e.g. "2011"
#' @param offline single logical value
#' @keywords internal
rtf_fetch_year <- function(year, offline = TRUE) {
  year <- as.character(year)
  assert_string(year, pattern = "[[:digit:]]{4}")
  assert_flag(offline)

  rtf_dat <- icd9_sources[icd9_sources$f_year == year, ]
  fn <- rtf_dat$rtf_filename

  unzip_to_data_raw(rtf_dat$rtf_url, file_name = fn, offline = offline)
}

#' parse RTF description of entire ICD-9-CM for a specific year
#'
#' Currently only the most recent update is implemented. Note that CMS have
#' published additional ICD-9-CM billable code lists since the last one from the
#' CDC: I think these have been the same every year since 2011, though. The last
#' CDC release is \code{Dtab12.rtf} from 2011.
#'
#' The file itself is 7 bit ASCII, but has its own internal encoding using
#' 'CP1252.' Test 'Meniere's' disease with lines 24821 to 24822 from 2012 RTF
#' @param year from 1996 to 2012 (this is what CDC has published). Only 2012
#'   implemented thus far
#' @template save_data
#' @template verbose
#' @source
#' http://ftp.cdc.gov/pub/Health_Statistics/NCHS/Publications/ICD9-CM/2011/Dtab12.zip
#' and similar files run from 1996 to 2011.
#' @keywords internal
rtf_parse_year <- function(year = "2011", ..., save_data = FALSE, verbose = FALSE, offline = TRUE) {
  assert_string(year)
  assert_flag(save_data)
  assert_flag(verbose)
  assert_flag(offline)

  f_info_rtf <- rtf_fetch_year(year, offline = offline)

  if (is.null(f_info_rtf))
    stop("RTF data for year ", year, " unavailable.")

  fp <- f_info_rtf$file_path

  fp_conn <- file(fp, encoding = "ASCII")
  on.exit(close(fp_conn))
  rtf_lines <- readLines(fp_conn, warn = FALSE, encoding = "ASCII")

  out <- rtf_parse_lines(rtf_lines, verbose = verbose,
                         ..., save_extras = save_data)
  out <- swap_names_vals(out)
  out <- icd_sort.icd9(out, short_code = FALSE)

  invisible(
    data.frame(
      code = out %>%
        unname %>%
        icd_decimal_to_short.icd9 %>%
        icd9cm,
      desc = names(out),
      stringsAsFactors = FALSE)
  )
}

rtf_pre_filter <- function(filtered, ...) {
  assert_character(filtered)
  # merge any line NOT starting with "\\par" on to previous line
  non_par_lines <- grep(pattern = "^\\\\par", x = filtered, invert = TRUE, ...)
  # in reverse order, put each non-par line on end of previous, then filter out
  # all non-par lines
  for (i in rev(non_par_lines))
    filtered[i - 1] <- paste(filtered[i - 1], filtered[i], sep = "")

  filtered <- grep("^\\\\par", filtered, value = TRUE, ...)
  filtered <- rtf_fix_unicode(filtered, ...)
  # extremely long terminal line in primary source is junk
  longest_lines <- which(nchar(filtered) > 3000L)
  filtered <- filtered[-longest_lines]
  filtered <- rtf_strip(filtered)
  grep("^[[:space:]]*$", filtered, value = TRUE, invert = TRUE, ...)
}

#' parse lines of RTF
#'
#' parse a character vector containing RTF strings
#'
#' \code{...} might include: \code{perl = TRUE, useBytes = TRUE}
#' @param rtf_lines character vector containing RTF. Encoding?
#' @template verbose
#' @return named character vector, with names being the ICD-9 codes, and the
#'   contents being the descriptions from the RTF source. Elsewhere I do this
#'   the other way around, but the tests are now wired for this layout. 'Tidy'
#'   data would favour having an unnamed two-column data frame.
#' @examples
#' \dontrun{
#' f_info_rtf <- rtf_fetch_year("2011", offline = FALSE)
#' rtf_lines <- readLines(f_info_rtf$file_path, warn = FALSE, encoding = "ASCII")
#' microbenchmark::microbenchmark(
#'   res_both <- rtf_parse_lines(rtf_lines, perl = TRUE, useBytes = TRUE),
#'   res_none <- rtf_parse_lines(rtf_lines, perl = FALSE, useBytes = FALSE),
#'   res_bytes <- rtf_parse_lines(rtf_lines, perl = FALSE, useBytes = TRUE),
#'   res_perl <- rtf_parse_lines(rtf_lines, perl = TRUE, useBytes = FALSE),
#'   times = 5
#' )
#' stopifnot(identical(res_both, res_none))
#' }
#' @keywords internal
rtf_parse_lines <- function(rtf_lines, verbose = FALSE, save_extras = FALSE, ...) {
  assert_character(rtf_lines)
  assert_flag(verbose)
  assert_flag(save_extras)

  filtered <- rtf_pre_filter(rtf_lines, ...)

  rtf_make_majors(filtered, save = save_extras, ...)
  rtf_make_sub_chapters(filtered, ..., save = save_extras)

  # this is so ghastly: find rows with sequare brackets containing definition of
  # subset of fourth or fifth digit codes. Need to pull code from previous row,
  # and create lookup, so we can exclude these when processing the fourth an
  # fifth digits
  invalid_qual <- rtf_make_invalid_qual(filtered, ...)

  # several occurances of "Requires fifth digit", referring back to the previous
  # higher-level definition, without having the parent code in the line itself
  re_fifth_range_other <- "fifth +digit +to +identify +stage"

  fifth_backref <- grep(re_fifth_range_other, filtered, ...)
  # for these, construct a string which will be captured in the next block
  # e.g. "Requires fifth digit to identify stage:" becomes
  # "Requires fifth digit to identify stage: 634 Spontaneous abortion"
  filtered[fifth_backref] <- paste(filtered[fifth_backref], filtered[fifth_backref - 1])

  re_fourth_range <- "fourth-digit.+categor"
  fourth_rows <- grep(re_fourth_range, filtered, ...)
  lookup_fourth <- rtf_generate_fourth_lookup(filtered, fourth_rows)
  # at least two examples of "Use 0 as fourth digit for category 672"
  re_fourth_digit_zero <- "Use 0 as fourth digit for category"
  fourth_digit_zero_lines <- grep(re_fourth_digit_zero, filtered, ...)
  filtered[fourth_digit_zero_lines] %>%
    str_pair_match("(.*category )([[:digit:]]{3})$", ...) %>%
    unname -> fourth_digit_zero_categories

  # deal with 657 and 672 (in the default RTF), by appending the elements to the
  # end of the input list. argh.
  for (categ in fourth_digit_zero_categories) {
    parent_row <- grep(paste0("^", categ, " .+"), filtered, value = TRUE, ...)
    filtered[length(filtered) + 1] <-
      paste0(categ, ".0 ", str_pair_match(parent_row, "([[:digit:]]{3} )(.+)", ...))
  }

  lookup_fifth <- rtf_make_lookup_fifth(filtered, re_fifth_range_other)

  filtered <- rtf_filter_excludes(filtered, ...)
  out <- rtf_main_filter(filtered, ...)
  out <- c(out, rtf_lookup_fourth(out = out, lookup_fourth = lookup_fourth))
  out <- c(out, rtf_lookup_fifth(out, lookup_fifth))
  out <- rtf_fix_duplicates(out, verbose)
  out <- out[-which(names(out) %in% invalid_qual)]

  rtf_fix_quirks_2015(out)
}

#' exclude some unwanted rows from filtered RTF
#'
#' Ignore excluded codes, and fix some odd-balls so they don't get dropped
#' "707.02Upper back", "066.40West Nile fever, unspecified", etc
#' @keywords internal
rtf_filter_excludes <- function(filtered, ...) {
  # drop excludes: lines with bracketed codes (removes chapter headings)
  re_bracketed <- paste0("\\((", re_icd9_decimal_bare,
                         ")-(", re_icd9_decimal_bare, ")\\)")
  filtered <- grep(re_bracketed, filtered, value = TRUE, invert = TRUE, ...)
  filtered <- grep("Exclude", filtered,
                   value = TRUE, invert = TRUE, ...)

  sub("((70[[:digit:]]\\.[[:digit:]]{2})|066\\.40)([[:alpha:]])", "\\1 \\2",
      filtered, ...)
}

#' filter RTF for actual ICD-9 codes
#'
#' Keep some more information, but we'll just take the primary description for
#' each item, i.e. where a code begins a line. Some codes have ten or so
#' alternative descriptions, e.g. 410.0
#' @keywords internal
rtf_main_filter <- function(filtered, ...) {
  filtered <- grep(paste0("^[[:space:]]*(", re_icd9_decimal_strict_bare, ") "),
                   filtered, value = TRUE, ...)

  # spaces to single
  filtered <- gsub("[[:space:]]+", " ", filtered, ...)
  # fix a few things, e.g. "040. 1 Rhinoscleroma", "527 .0 Atrophy"
  filtered <-
    sub("^([VvEe]?[[:digit:]]+) ?\\. ?([[:digit:]]) (.*)", "\\1\\.\\2 \\3",
        filtered, ...)
  # and high-level headings like "210-229 Benign neoplasms"
  filtered <- grep("^[[:space:]]*[[:digit:]]{3}-[[:digit:]]{3}.*", filtered,
                   value = TRUE, invert = TRUE, ...)
  # "2009 H1 N1 swine influenza virus"
  filtered <- grep("^2009", filtered, value = TRUE, invert = TRUE, ...)
  # "495.7 \"Ventilation\" pneumonitis"
  re_code_desc <- paste0("^(", re_icd9_decimal_bare, ") +([ \"[:graph:]]+)")
  # out is the start of the eventual output of code to description pairs. seems
  # to be quicker with perl and useBytes both FALSE
  str_pair_match(filtered, re_code_desc, perl = FALSE, useBytes = FALSE)
}

rtf_make_majors <- function(filtered, ..., save = FALSE) {
  use_bytes <- list(...)[["useBytes"]]
  major_lines <- grep(paste0("^(", re_icd9_major_strict_bare, ") "),
                      filtered, value = TRUE)
  re_major_split <- "([^[:space:]]+)[[:space:]]+(.+)"
  icd9_majors <- gsub(pattern = re_major_split, replacement = "\\1",
                      x = major_lines, perl = TRUE, useBytes = use_bytes)
  names(icd9_majors) <- gsub(pattern = re_major_split, replacement = "\\2",
                             x = major_lines, perl = TRUE, useBytes = use_bytes)

  # this sub-chapter is simply missing from the otherwise consistent RTF way
  # 'major' types are reported:
  icd9_majors[["Place of occurrence"]] <- "E849"

  # There are some duplicates created by the major search, mostly E001 to E030
  # which are just listed twice in RTF. Also 199 (with punctuation difference),
  # 209 and 239.
  icd9_majors <- icd9_majors[!duplicated(icd9_majors)]

  if (save)
    save_in_data_dir(icd9_majors)

  invisible(icd9_majors)
}

rtf_make_sub_chapters <- function(filtered, ..., save = FALSE) {
  re_subchap_either <- paste0(
    "^[-()A-Z,[:space:]]+", "(", "[[:space:]]+\\(", "|", "\\(", ")",
    "(", re_icd9_major_strict_bare, ")",
    "(-(", re_icd9_major_strict_bare, "))?",
    "\\)")
  chapter_to_desc_range.icd9(
    grep(re_subchap_either, filtered,
         value = TRUE, ...)
  )
  # The entire "E" block is incorrectly identified here, so make sure it is gone:
  icd9_sub_chapters["Supplementary Classification Of Factors Influencing Health Status And Contact With Health Services"] <- NULL
  icd9_sub_chapters["Supplementary Classification Of External Causes Of Injury And Poisoning"] <- NULL

  if (save)
    save_in_data_dir(icd9_sub_chapters)

  invisible(icd9_sub_chapters)
}

rtf_make_invalid_qual <- function(filtered, ...) {
  re_qual_subset <- "\\[[-, [:digit:]]+\\]"
  qual_subset_lines <- grep(re_qual_subset, filtered, ...)
  invalid_qual <- c()
  for (ql in qual_subset_lines) {
    # get prior code
    filtered[ql - 1] %>%
      str_match_all(paste0("(", re_icd9_decimal_bare, ") (.*)")) %>%
      unlist %>% extract2(2) -> code
    sb <- rtf_parse_qualifier_subset(filtered[ql])
    inv_sb <- setdiff(as.character(0:9), sb)
    if (length(inv_sb) == 0)
      next
    if (grepl("\\.", code, ...))
      invalid_qual <- c(invalid_qual, paste0(code, inv_sb))
    else
      invalid_qual <- c(invalid_qual, paste0(code, ".", inv_sb))
  }
  invalid_qual
}

#' generate look-up for four digit codes
#'
#' \code{lookup_fourth} will contain vector of suffices, with names being the
#' codes they augment
#' @return named character vector, names are the ICD codes, values are the
#'   descriptions
#' @keywords internal
rtf_generate_fourth_lookup <- function(filtered, fourth_rows, verbose = FALSE) {
  lookup_fourth <- c()
  for (f in fourth_rows) {
    range <- rtf_parse_fifth_digit_range(filtered[f])

    fourth_suffices <- str_pair_match(
      string = filtered[seq(f + 1, f + 37)],
      pattern = "^([[:digit:]])[[:space:]](.*)"
    )

    re_fourth_defined <- paste(c("\\.[", names(fourth_suffices), "]$"), collapse = "")
    # drop members of range which don't have defined fourth digit
    range <- grep(re_fourth_defined, range, value = TRUE)
    # now replace value with the suffix, with name of item being the code itself
    names(range) <- range
    last <- -1
    for (fourth in names(fourth_suffices)) {
      if (last > as.integer(fourth)) break
      re_fourth <- paste0("\\.", fourth, "$")

      range[grep(re_fourth, range)] <- fourth_suffices[fourth]
      last <- fourth
    }
    lookup_fourth <- c(lookup_fourth, range)
  }
  if (verbose) {
    message("lookup_fourth has length: ", length(lookup_fourth), ", head: ")
    print(head(lookup_fourth))
  }
  lookup_fourth
}

#' apply fourth digit qualifiers
#'
#' use the lookup table of fourth digit
#'
#' @keywords internal
rtf_lookup_fourth <- function(out, lookup_fourth, verbose = FALSE) {
  rtf_lookup_fourth_alt_env(out = out, lookup_fourth = lookup_fourth, verbose = verbose)
}

rtf_lookup_fourth_alt_base <- function(out, lookup_fourth, verbose = FALSE) {
  out_fourth <- c()
  for (f_num in seq_along(lookup_fourth)) {
    lf <- lookup_fourth[f_num]
    f <- names(lf)
    parent_code <- icd_get_major.icd9(f, short_code = FALSE)
    if (parent_code %in% names(out)) {
      pair_fourth <- paste(out[parent_code], lf, sep = ", ")
      names(pair_fourth) <- f
      out_fourth <- append(out_fourth, pair_fourth)
    }
  }
  if (verbose) {
    message("fourth output lines: length = ", length(out_fourth), ", head: ")
    print(head(out_fourth))
  }
  out_fourth
}

rtf_lookup_fourth_alt_env <- function(out, lookup_fourth, verbose = FALSE) {
  out_fourth <- c()
  out_env <- list2env(as.list(out))
  for (f_num in seq_along(lookup_fourth)) {
    lf <- lookup_fourth[f_num]
    f <- names(lf)
    parent_code <- icd_get_major.icd9(f, short_code = FALSE)
    if (!is.null(out_env[[parent_code]])) {
      pair_fourth <- paste(out[parent_code], lf, sep = ", ")
      names(pair_fourth) <- f
      out_fourth <- append(out_fourth, pair_fourth)
    }
  }
  if (verbose) {
    message("fourth output lines: length = ", length(out_fourth), ", head: ")
    print(head(out_fourth))
  }
  rm(out_env)
  out_fourth
}

rtf_make_lookup_fifth <- function(filtered, re_fifth_range_other, ..., verbose = FALSE) {
  re_fifth_range <- "ifth-digit subclas|fifth-digits are for use with codes"
  re_fifth_rows <- paste(re_fifth_range, re_fifth_range_other, sep = "|")
  fifth_rows <- grep(pattern = re_fifth_rows, x = filtered, ...)

  # lookup_fifth will contain vector of suffices, with names being the codes
  # they augment
  lookup_fifth <- c()
  for (f in fifth_rows) {
    if (verbose) message("working on fifth-digit row:", f)
    range <- rtf_parse_fifth_digit_range(filtered[f], verbose = verbose)
    fifth_suffices <- filtered[seq(f + 1, f + 20)] %>%
      grep(pattern = "^[[:digit:]][[:space:]].*", value = TRUE, ...) %>%
      str_pair_match("([[:digit:]])[[:space:]](.*)", ...)

    re_fifth_defined <- paste(c("\\.[[:digit:]][", names(fifth_suffices), "]$"), collapse = "")
    # drop members of range which don't have defined fifth digit
    range <- grep(re_fifth_defined, range, value = TRUE, ...)
    # now replace value with the suffix, with name of item being the code itself
    names(range) <- range
    last <- -1L
    for (fifth in names(fifth_suffices)) {
      if (last > as.integer(fifth)) break
      re_fifth <- paste0("\\.[[:digit:]]", fifth, "$")
      range[grep(re_fifth, range)] <- fifth_suffices[fifth]
      last <- fifth
    }
    lookup_fifth <- c(lookup_fifth, range)
  }

  # V30-39 are a special case because combination of both fourth and fifth
  # digits are specified
  re_fifth_range_V30V39 <- "The following two fifths-digits are for use with the fourth-digit \\.0"
  re_V30V39_fifth <- "V3[[:digit:]]\\.0[01]$"

  lines_V30V39 <- grep(re_fifth_range_V30V39, filtered)
  stopifnot(length(lines_V30V39) == 1)
  filtered[seq(from = lines_V30V39 + 1, to = lines_V30V39 + 3)] %>%
    grep(pattern = "^[[:digit:]][[:space:]].*", value = TRUE, ...) %>%
    str_pair_match("([[:digit:]])[[:space:]](.*)", ...) -> suffices_V30V39
  range <- c("V30" %i9da% "V37", icd_children.icd9("V39", short_code = FALSE, defined = FALSE))
  range <- grep(re_V30V39_fifth, range, value = TRUE, ...)
  names(range) <- range
  for (fifth in names(suffices_V30V39)) {
    # only applies to .0x (in 2015 at least), but .1 also exists without 5th
    # digit
    re_fifth <- paste0("\\.0", fifth, "$")
    range[grep(re_fifth, range, ...)] <- suffices_V30V39[fifth]
  }
  c(lookup_fifth, range)
}

rtf_lookup_fifth <- function(out, lookup_fifth, verbose = FALSE) {
  rtf_lookup_fifth_alt_env(out = out, lookup_fifth = lookup_fifth, verbose = verbose)
}

rtf_lookup_fifth_alt_base <- function(out, lookup_fifth, verbose = FALSE) {
  out_fifth <- c()
  for (f_num in seq_along(lookup_fifth)) {
    lf <- lookup_fifth[f_num]
    f <- names(lf)
    parent_code <- substr(f, 0, nchar(f) - 1)

    if (parent_code %in% names(out)) {
      pair_fifth <- paste(out[parent_code], lf, sep = ", ")
      names(pair_fifth) <- f
      out_fifth <- c(out_fifth, pair_fifth)
    }
  }
  if (verbose) {
    message("fifth output lines: length = ", length(out_fifth), ", head: ")
    print(head(out_fifth))
  }
  out_fifth
}

rtf_lookup_fifth_alt_env <- function(out, lookup_fifth, verbose = FALSE) {
  out_fifth <- character(5000) # 2011 data is 4870 long
  n <- 1L
  out_env <- list2env(as.list(out))

  for (f_num in seq_along(lookup_fifth)) {
    lf <- lookup_fifth[f_num]
    f <- names(lf)
    parent_code <- substr(f, 0, nchar(f) - 1)
    if (!is.null(out_env[[parent_code]])) {
      out_fifth[n] <- paste(out[parent_code], lf, sep = ", ")
      names(out_fifth)[n] <- f
      n <- n + 1L
    }
  }
  out_fifth <- out_fifth[1:n - 1]
  if (verbose) {
    message("fifth output lines: length = ", length(out_fifth), ", head: ")
    print(head(out_fifth))
  }
  out_fifth
}

#' Fix Unicode characters in RTF
#'
#' fix ASCII, Code Page 1252 and Unicode horror: some character definitions are
#' split over lines... This needs care in Windows, or course. Maybe Mac, too?
#'
#' First: c cedilla, e grave, e acute Then:  n tilde, o umlaut
#' @examples
#' \dontrun{
#' # rtf_fix_unicode is a slow step, useBytes and perl together is faster
#' f_info_rtf <- rtf_fetch_year("2011", offline = FALSE)
#' rtf_lines <- readLines(f_info_rtf$file_path, warn = FALSE, encoding = "ASCII")
#' microbenchmark::microbenchmark(
#'   res_both <- rtf_fix_unicode(rtf_lines, perl = TRUE, useBytes = TRUE),
#'   res_none <- rtf_fix_unicode(rtf_lines, perl = FALSE, useBytes = FALSE),
#'   res_bytes <- rtf_fix_unicode(rtf_lines, perl = FALSE, useBytes = TRUE),
#'   res_perl <- rtf_fix_unicode(rtf_lines, perl = TRUE, useBytes = FALSE),
#'   times = 5
#' )
#' stopifnot(identical(res_both, res_none))
#' }
#' @keywords internal manip
rtf_fix_unicode <- function(filtered, ...) {
  filtered <- gsub("\\\\'e7", "\u00e7", filtered, ...) # c cedilla
  filtered <- gsub("\\\\'e8", "\u00e8", filtered, ...) # e gravel
  filtered <- gsub("\\\\'e9", "\u00e9", filtered, ...) # e acute
  filtered <- gsub("\\\\'f1", "\u00f1", filtered, ...) # n tilde
  filtered <- gsub("\\\\'f6", "\u00f6", filtered, ...) # o umlaut
  enc2utf8(filtered)
}

#' fix duplicates detected in RTF parsing
#'
#' clean up duplicates (about 350 in 2015 data), mostly one very brief
#' description and a correct longer one; or, identical descriptions
#' @keywords internal
rtf_fix_duplicates <- function(out, verbose) {

  dupes <- out[duplicated(names(out)) | duplicated(names(out), fromLast = TRUE)]
  dupes <- unique(names(dupes))

  for (d in dupes) {
    dupe_rows <- which(names(out) == d)
    if (all(out[dupe_rows[1]] == out[dupe_rows[-1]])) {
      out <- out[-dupe_rows[-1]]
      next
    }
    desclengths <- nchar(out[dupe_rows])
    max_len <- max(desclengths)
    if (verbose)
      message("removing differing duplicates: ", paste(out[dupe_rows]))
    out <- out[-dupe_rows[-which(desclengths != max_len)]]
  }
  out
}

#' fix quirks for 2015 RTF parsing
#'
#' 2015 quirks (many more are baked into the parsing: try to splinter out the
#' most specific) some may well apply to other years 650-659 ( and probably many
#' others don't use whole subset of fourth or fifth digit qualifiers) going to
#' have to parse these, e.g. [0,1,3], as there are so many...
#' @keywords internal manip
rtf_fix_quirks_2015 <- function(out) {
  out <- out[grep("65[12356789]\\.[[:digit:]][24]", names(out), invert = TRUE)]

  #657 just isn't formatted like any other codes
  out["657.0"] <- "Polyhydramnios"
  out["657.00"] <-
    "Polyhydramnios, unspecified as to episode of care or not applicable"
  out["657.01"] <-
    "Polyhydramnios, delivered, with or without mention of antepartum condition"
  out["657.03"] <- "Polyhydramnios, antepartum condition or complication"

  out["719.69"] <- "Other symptoms referable to joint, multiple sites"
  out["807.19"] <- "Open fracture of multiple ribs, unspecified"
  out["E849"] <- "Place of occurence"
  out
}

#' parse a row of RTF source data for ranges to apply fifth digit
#'
#'   sub-classifications
#' returns all the possible 5 digit codes encompassed by the given
#'   definition. This needs to be whittled down to just those matching fifth
#'   digits, but we haven't parsed them yet.
#' @template verbose
#' @keywords internal
rtf_parse_fifth_digit_range <- function(row_str, verbose = FALSE) {
  assert_string(row_str)
  assert_flag(verbose)

  out <- c()
  # get numbers and number ranges
  row_str %>%
    strsplit("[, :;]") %>%
    unlist %>%
    grep(pattern = "[VvEe]?[0-9]", value = TRUE) -> vals

  if (verbose)
    message("vals are:", paste(vals, collapse = ", "))

  # sometimes  we get things like:
  # [1] "345.0" ".1"    ".4-.9"
  grepl(pattern = "^\\.[[:digit:]]+.*", vals) -> decimal_start
  if (any(decimal_start)) {
    base_code <- vals[1] # assume first is the base
    stopifnot(icd_is_valid.icd9(base_code, short_code = FALSE))
    for (dotmnr in vals[-1]) {
      if (verbose)
        message("dotmnr is: ", dotmnr)
      if (grepl("-", dotmnr)) {
        # range of minors
        strsplit(dotmnr, "-", fixed = TRUE) %>% unlist -> pair
        first <- paste0(icd_get_major.icd9(base_code, short_code = FALSE), pair[1])
        last <- paste0(icd_get_major.icd9(base_code, short_code = FALSE), pair[2])
        if (verbose)
          message("expanding specified minor range from ", first, " to ", last)
        out <- c(out, first %i9da% last)
      } else {
        single <- paste0(icd_get_major.icd9(base_code, short_code = FALSE), dotmnr)
        out <- c(out, icd_children.icd9(single, short_code = FALSE, defined = FALSE))
      }
    }
    vals <- vals[1] # still need to process the base code
  }

  for (v in vals) {
    # take care of ranges
    if (grepl("-", v)) {
      pair <- strsplit(v, "-", fixed = TRUE) %>% unlist
      # sanity check
      stopifnot(all(icd_is_valid.icd9(pair, short_code = FALSE)))
      if (verbose)
        message("expanding explicit range ", pair[1], " to ", pair[2])
      # formatting errors can lead to huge range expansions, e.g. "8-679"

      # quickly strip off V or E part for comparison
      pair_one <- gsub("[^[:digit:]]", "", pair[1])
      pair_two <- gsub("[^[:digit:]]", "", pair[2])
      if (as.integer(pair_two) - as.integer(pair_one) > 10) {
        warning("probable formatting misinterpretation: huge range expansion")
      }

      out <- c(out, pair[1] %i9da% pair[2])
    } else {
      # take care of single values
      if (!icd_is_valid.icd9(v, short_code = FALSE))
        stop(paste("invalid code is: ",
                   icd_get_invalid.icd9(v, short_code = FALSE)))
      out <- c(out, icd_children.icd9(v, short_code = FALSE, defined = FALSE))
    }

  }
  out
}

rtf_parse_qualifier_subset <- function(qual) {
  assert_string(qual) # one at a time
  out <- c()
  strip(qual) %>%
    strsplit("[]\\[,]") %>%
    unlist %>%
    grep(pattern = "[[:digit:]]", value = TRUE) %>%
    strsplit(",") %>% unlist -> vals
  for (v in vals) {
    if (grepl("-", v)) {
      strsplit(v, "-") %>%
        unlist %>%
        as.integer -> pair
      out <- c(out, seq(pair[1], pair[2]))
      next
    }
    out <- c(out, as.integer(v))
  }
  as.character(out)
}

#' Strip RTF
#'
#' Take a vector of character strings containing RTF, replace each \\tab with a
#' space and eradicate all other RTF symbols
#'
#' just for \\tab, replace with space, otherwise, drop RTF tags entirely
#' @param x vector of character strings containing RTF
#' @examples
#' \dontrun{
#' # rtf_strip is a slow step, useBytes and perl together is five times faster
#' f_info_rtf <- rtf_fetch_year("2011", offline = FALSE)
#' rtf_lines <- readLines(f_info_rtf$file_path, warn = FALSE, encoding = "ASCII")
#' microbenchmark::microbenchmark(
#'   res_both <- rtf_strip(rtf_lines, perl = TRUE, useBytes = TRUE),
#'   res_none <- rtf_strip(rtf_lines, perl = FALSE, useBytes = FALSE),
#'   res_bytes <- rtf_strip(rtf_lines, perl = FALSE, useBytes = TRUE),
#'   res_perl <- rtf_strip(rtf_lines, perl = TRUE, useBytes = FALSE),
#'   times = 5
#' )
#' stopifnot(identical(res_both, res_none))
#' }
#' @keywords internal manip
rtf_strip <- function(x, ...) {
  #nolint start
  x <- gsub("\\\\tab ", " ", x, ...)
  x <- gsub("\\\\[[:punct:]]", "", x, ...) # control symbols only, not control words
  x <- gsub("\\\\lsdlocked[ [:alnum:]]*;", "", x, ...) # special case
  x <- gsub("\\{\\\\bkmk(start|end).*?\\}", "", x, ...)
  # no backslash in this next list, others removed from
  # http://www.regular-expressions.info/posixbrackets.html
  # punct is defined as:       [!"\#$%&'()*+,\-./:;<=>?@\[\\\]^_`{|}~], not quite the same
  x <- gsub("\\\\[-[:alnum:]]*[ !\"#$%&'()*+,-./:;<=>?@^_`{|}~]?", "", x, ...)
  x <- gsub(" *(\\}|\\{)", "", x, ...)
  trim(x)
  #nolint end
}
