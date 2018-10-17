# Resolve footnotes or styles
#' @importFrom dplyr filter bind_rows mutate inner_join select arrange pull
#' @importFrom tibble rownames_to_column
#' @noRd
resolve_footnotes_styles <- function(output_df,
                                     boxh_df,
                                     groups_rows_df,
                                     opts_df,
                                     arrange_groups,
                                     boxhead_spanners,
                                     title_defined,
                                     headnote_defined,
                                     footnotes_df = NULL,
                                     styles_df = NULL) {

  if (!is.null(styles_df) && is.null(footnotes_df)) {
    tbl <- styles_df
  } else if (is.null(styles_df) && !is.null(footnotes_df)) {
    tbl <- footnotes_df
  }

  # Pare down to the relevant records
  if (nrow(tbl) > 0) {

    # Filter `tbl` by elements preceeding the data rows (i.e., if element is not
    # present but a reference is, remove the footnote reference since it is not
    # relevant)

    # Filter by `title`
    if (title_defined == FALSE) {

      tbl <- tbl %>%
        dplyr::filter(locname != "title")
    }

    # Filter by `headnote`
    if (headnote_defined == FALSE) {

      tbl <- tbl %>%
        dplyr::filter(locname != "headnote")
    }

    # Filter by `grpname` in boxhead groups
    if ("boxhead_groups" %in% tbl[["locname"]]) { # remove conditional

      tbl <- tbl %>%
        dplyr::filter(locname != "boxhead_groups" | grpname %in% boxhead_spanners)
    }

    # Filter by `grpname` in stub groups
    if ("stub_groups" %in% tbl[["locname"]]) {

      tbl <-
        dplyr::bind_rows(
          tbl %>%
            dplyr::filter(locname != "stub_groups"),
          tbl %>%
            dplyr::filter(locname == "stub_groups") %>%
            dplyr::filter(grpname %in% arrange_groups$groups))
    }

    # Filter `tbl` by the remaining columns in `output_df`
    tbl <- tbl %>%
      dplyr::filter(colname %in% c(NA_character_, colnames(output_df)))
  }

  # Reorganize records that target the data rows
  if (5 %in% tbl[["locnum"]]) {

    tbl_not_data <- tbl %>%
      dplyr::filter(locnum != 5 | locname == "stub_groups")

    tbl_data <- tbl %>%
      dplyr::filter(locnum == 5 & locname != "stub_groups")

    if (nrow(tbl_data) > 0) {

      # Re-map the `rownum` to the new row numbers for the
      # data rows
      tbl_data <- tbl_data %>%
        dplyr::mutate(rownum = rownum_translation(
          output_df, rownum_start = rownum))

      # Add a `colnum` column that's required for arranging `tbl` in such a way
      # that the order of records moves from top-to-bottom, left-to-right
      tbl_data <- tbl_data %>%
        dplyr::mutate(colnum = colname_to_colnum(
          boxh_df = boxh_df, colname = colname)) %>%
        dplyr::mutate(colnum = ifelse(locname == "stub", 0, colnum))
    }

    # Re-combine `tbl_data` with `tbl`
    tbl <- dplyr::bind_rows(tbl_not_data, tbl_data)

  } else {
    tbl <- tbl %>%
      dplyr::mutate(colnum = NA_integer_)
  }

  # For the stub groups, insert a `rownum` based on groups_rows_df
  if ("stub_groups" %in% tbl[["locname"]]) {

    tbl_not_stub_groups <- tbl %>%
      dplyr::filter(locname != "stub_groups")

    tbl_stub_groups <- tbl %>%
      dplyr::filter(locname == "stub_groups") %>%
      dplyr::inner_join(
        groups_rows_df %>% dplyr::select(-group_label),
        by = c("grpname" = "group")) %>%
      dplyr::mutate(rownum = row - 0.1) %>%
      dplyr::select(-row, -row_end)

    # Re-combine `tbl_not_stub_groups`
    #   with `tbl_stub_groups`
    tbl <-
      dplyr::bind_rows(
        tbl_not_stub_groups, tbl_stub_groups)
  }

  # For the summary cells, insert a `rownum` based on groups_rows_df
  if ("summary_cells" %in% tbl[["locname"]]) {

    tbl_not_summary_cells <- tbl %>%
      dplyr::filter(locname != "summary_cells")

    tbl_summary_cells <- tbl %>%
      dplyr::filter(locname == "summary_cells") %>%
      dplyr::inner_join(
        groups_rows_df %>% dplyr::select(-group_label),
        by = c("grpname" = "group")) %>%
      dplyr::mutate(rownum = (rownum / 100) + row_end) %>%
      dplyr::select(-row, -row_end)

    # Re-combine `tbl_not_summary_cells`
    #   with `tbl_summary_cells`
    tbl <-
      dplyr::bind_rows(
        tbl_not_summary_cells, tbl_summary_cells)
  }

  if (!("colnum" %in% colnames(tbl))) {

    tbl <- tbl %>%
      dplyr::mutate(colnum = NA_integer_)
  }

  # Sort the table rows
  tbl <- tbl %>%
    dplyr::arrange(locnum, rownum, colnum)

  # Generate a lookup table with ID'd footnote
  # text elements (that are distinct)
  lookup_tbl <- tbl %>%
    dplyr::select(text) %>%
    dplyr::distinct() %>%
    tibble::rownames_to_column(var = "fs_id") %>%
    dplyr::mutate(fs_id = as.integer(fs_id))

  # Join the lookup table to `tbl`
  tbl <- tbl %>%
    dplyr::inner_join(lookup_tbl, by = "text")

  if (nrow(tbl) > 0) {

    # Get the glyph option from `opts_df`
    glyphs <- opts_df %>%
      dplyr::filter(parameter == "footnote_glyph") %>%
      dplyr::pull(value)

    # Modify `fs_id` to contain the glyphs we need
    tbl <- tbl %>%
      dplyr::mutate(
        fs_id = footnote_glyphs(
          x = fs_id,
          glyphs = glyphs))
  }

  tbl
}

#' @importFrom dplyr filter group_by mutate ungroup select distinct
#' @noRd
set_footnote_glyphs_boxhead <- function(footnotes_resolved,
                                        boxh_df,
                                        output = "html") {

  # Get the resolved footnotes
  footnotes_tbl <- footnotes_resolved

  # Get the `boxh_df` object
  boxh_df <- boxh_df

  # If there are any footnotes to apply to the boxhead,
  # process them individually for the spanner groups and
  # for the column label groups
  if (any(c("boxhead_columns", "boxhead_groups") %in% footnotes_tbl$locname)) {

    footnotes_tbl <-
      footnotes_tbl %>%
      dplyr::filter(locname %in% c("boxhead_columns", "boxhead_groups"))

    # Filter the boxhead spanner group footnotes
    footnotes_boxhead_group_tbl <-
      footnotes_tbl %>%
      dplyr::filter(!is.na(grpname))

    # Filter the boxhead column label footnotes
    footnotes_boxhead_column_tbl <-
      footnotes_tbl %>%
      dplyr::filter(!is.na(colname))

    if (nrow(footnotes_boxhead_group_tbl) > 0) {

      footnotes_boxhead_group_glyphs <-
        footnotes_boxhead_group_tbl %>%
        dplyr::group_by(grpname) %>%
        dplyr::mutate(fs_id_coalesced = paste(fs_id, collapse = ",")) %>%
        dplyr::ungroup() %>%
        dplyr::select(grpname, fs_id_coalesced) %>%
        dplyr::distinct()

      for (i in seq(nrow(footnotes_boxhead_group_glyphs))) {

        column_indices <-
          which(boxh_df["group_label", ] == footnotes_boxhead_group_glyphs$grpname[i])

        text <-
          boxh_df["group_label", column_indices] %>%
          unlist() %>% unname() %>% unique()

        if (output == "html") {

          text <-
            paste0(
              text,
              footnote_glyph_to_html(
                footnotes_boxhead_group_glyphs$fs_id_coalesced[i]))

        } else if (output == "rtf") {

          text <-
            paste0(
              text,
              footnote_glyph_to_rtf(
                footnotes_boxhead_group_glyphs$fs_id_coalesced[i]))

        } else if (output == "latex") {

          text <-
            paste0(
              text,
              footnote_glyph_to_latex(
                footnotes_boxhead_group_glyphs$fs_id_coalesced[i]))
        }

        boxh_df["group_label", column_indices] <- text
      }
    }

    if (nrow(footnotes_boxhead_column_tbl) > 0) {

      footnotes_boxhead_column_glyphs <-
        footnotes_boxhead_column_tbl %>%
        dplyr::group_by(colname) %>%
        dplyr::mutate(fs_id_coalesced = paste(fs_id, collapse = ",")) %>%
        dplyr::ungroup() %>%
        dplyr::select(colname, fs_id_coalesced) %>%
        dplyr::distinct()

      for (i in seq(nrow(footnotes_boxhead_column_glyphs))) {

        text <-
          boxh_df["column_label", footnotes_boxhead_column_glyphs$colname[i]]

        if (output == "html") {

          text <-
            paste0(
              text,
              footnote_glyph_to_html(
                footnotes_boxhead_column_glyphs$fs_id_coalesced[i]))

        } else if (output == "rtf") {

          text <-
            paste0(
              text,
              footnote_glyph_to_rtf(
                footnotes_boxhead_column_glyphs$fs_id_coalesced[i]))

        } else if (output == "latex") {

          text <-
            paste0(
              text,
              footnote_glyph_to_latex(
                footnotes_boxhead_column_glyphs$fs_id_coalesced[i]))
        }

        boxh_df[
          "column_label", footnotes_boxhead_column_glyphs$colname[i]] <- text
      }
    }
  }

  boxh_df
}

# Apply footnotes to the data rows
#' @importFrom dplyr filter group_by mutate ungroup select distinct
#' @noRd
apply_footnotes_to_output <- function(output_df,
                                      footnotes_resolved,
                                      output = "html") {

  # `data` location
  footnotes_tbl_data <-
    footnotes_resolved %>%
    dplyr::filter(locname %in% c("data", "stub"))

  if (nrow(footnotes_tbl_data) > 0) {

    if ("stub" %in% footnotes_tbl_data$locname &&
        "rowname" %in% colnames(output_df)) {

      footnotes_tbl_data[
        which(is.na(footnotes_tbl_data$colname)), "colname"] <-
        "rowname"
    }

    footnotes_data_glpyhs <-
      footnotes_tbl_data %>%
      dplyr::group_by(rownum, colnum) %>%
      dplyr::mutate(fs_id_coalesced = paste(fs_id, collapse = ",")) %>%
      dplyr::ungroup() %>%
      dplyr::select(colname, rownum, fs_id_coalesced) %>%
      dplyr::distinct()

    for (i in seq(nrow(footnotes_data_glpyhs))) {

      text <-
        output_df[footnotes_data_glpyhs$rownum[i], footnotes_data_glpyhs$colname[i]]

      if (output == "html") {

        text <-
          paste0(text, footnote_glyph_to_html(
            footnotes_data_glpyhs$fs_id_coalesced[i]))

      } else if (output == "rtf") {

        text <-
          paste0(text, footnote_glyph_to_rtf(
            footnotes_data_glpyhs$fs_id_coalesced[i]))

      } else if (output == "latex") {

        text <-
          paste0(text, footnote_glyph_to_latex(
            footnotes_data_glpyhs$fs_id_coalesced[i]))
      }

      output_df[
        footnotes_data_glpyhs$rownum[i], footnotes_data_glpyhs$colname[i]] <- text
    }
  }

  output_df
}

#' @importFrom dplyr filter group_by mutate ungroup select distinct
#' @importFrom htmltools htmlEscape
#' @noRd
set_footnote_glyphs_stub_groups <- function(footnotes_resolved,
                                            groups_rows_df,
                                            output = "html") {

  # Get the resolved footnotes
  footnotes_tbl <- footnotes_resolved

  if (!("stub_groups" %in% footnotes_tbl$locname)) {

    return(groups_rows_df)
  }

  footnotes_stub_groups_tbl <-
    footnotes_tbl %>%
    dplyr::filter(locname == "stub_groups")

  if (nrow(footnotes_stub_groups_tbl) > 0) {

    footnotes_stub_groups_glyphs <-
      footnotes_stub_groups_tbl %>%
      dplyr::group_by(grpname) %>%
      dplyr::mutate(fs_id_coalesced = paste(fs_id, collapse = ",")) %>%
      dplyr::ungroup() %>%
      dplyr::select(grpname, fs_id_coalesced) %>%
      dplyr::distinct()

    for (i in seq(nrow(footnotes_stub_groups_glyphs))) {

      row_index <-
        which(groups_rows_df[, "group_label"] == footnotes_stub_groups_glyphs$grpname[i])

      text <- htmltools::htmlEscape(groups_rows_df[row_index, "group_label"])

      if (output == "html") {

        text <-
          paste0(
            text,
            footnote_glyph_to_html(
              footnotes_stub_groups_glyphs$fs_id_coalesced[i]))

      } else if (output == "rtf") {

        text <-
          paste0(
            text,
            footnote_glyph_to_rtf(
              footnotes_stub_groups_glyphs$fs_id_coalesced[i]))

      } else if (output == "latex") {

        text <-
          paste0(
            text,
            footnote_glyph_to_latex(
              footnotes_stub_groups_glyphs$fs_id_coalesced[i]))
      }

      groups_rows_df[row_index, "group_label"] <- text
    }
  }

  groups_rows_df
}

# Apply footnotes to the summary rows
#' @importFrom dplyr filter group_by mutate ungroup select distinct
#' @noRd
apply_footnotes_to_summary <- function(list_of_summaries,
                                       footnotes_resolved) {

  summary_df_list <- list_of_summaries$summary_df_display_list

  if (!("summary_cells" %in% footnotes_resolved$locname)) {
    return(list_of_summaries)
  }

  footnotes_tbl_data <-
    footnotes_resolved %>%
    dplyr::filter(locname == "summary_cells")

  footnotes_data_glpyhs <-
    footnotes_tbl_data %>%
    dplyr::mutate(row = as.integer(round((rownum - floor(rownum)) * 100, 0))) %>%
    dplyr::group_by(grpname, row, colnum) %>%
    dplyr::mutate(fs_id_coalesced = paste(fs_id, collapse = ",")) %>%
    dplyr::ungroup() %>%
    dplyr::select(grpname, colname, row, fs_id_coalesced) %>%
    dplyr::distinct()

  for (i in seq(nrow(footnotes_data_glpyhs))) {

    text <-
      summary_df_list[[footnotes_data_glpyhs[i, ][["grpname"]]]][[
        footnotes_data_glpyhs$row[i], footnotes_data_glpyhs$colname[i]]]

    text <-
      paste0(text, footnote_glyph_to_html(footnotes_data_glpyhs$fs_id_coalesced[i]))

    summary_df_list[[footnotes_data_glpyhs[i, ][["grpname"]]]][[
      footnotes_data_glpyhs$row[i], footnotes_data_glpyhs$colname[i]]] <- text
  }

  list_of_summaries$summary_df_display_list <- summary_df_list

  list_of_summaries
}