#' Format multiple vectors in a tabular display
#'
#' The vectors are formatted to fit horizontally into a user-supplied number of
#' characters per row.
#'
#' @param x A list of vectors to format
#' @param has_row_id Include a column indicating row IDs? Pass `"*"` to mark
#'   the row ID column with a star.
#' @param width Default width of the entire output, optional
#' @param ... Ignored
#' @export
#' @examples
#' colonnade(list(a = 1:3, b = letters[1:3]))
#'
#' long_string <- list(paste(letters, collapse = " "))
#' colonnade(long_string, width = 20)
#' colonnade(long_string, has_row_id = FALSE, width = 20)
#'
#' # The width can also be overridden when calling format() or print():
#' print(colonnade(long_string), width = 20)
#'
#' # If width is larger than getOption("width"), multiple tiers are created:
#' colonnade(rep(long_string, 4), width = Inf)
colonnade <- function(x, has_row_id = TRUE, width = NULL, ...) {
  has_title <- is_named(x)
  if (has_title) {
    ret <- map2(x, names(x), pillar)
  } else {
    ret <- map(x, pillar)
  }
  if (!is_false(has_row_id) && length(x) > 0) {
    rowid <- rowidformat(
      length(x[[1]]),
      has_star = identical(has_row_id, "*"),
      has_title_row = has_title
    )
  } else {
    rowid <- NULL
  }
  zero_height <- length(x) == 0L || length(x[[1]]) == 0L
  ret <- structure(ret, zero_height = zero_height, rowid = rowid, class = "colonnade")
  ret <- set_width(ret, width)
  ret
}

#' @description
#' The `squeeze()` function is called by [format()]  and [print()] and usually
#' doesn't need to be called manually.
#' It returns an object suitable for printing and formatting at a fixed width
#' with additional information about omitted columns.
#'
#' @rdname colonnade
#' @export
#' @examples
#' squeeze(colonnade(long_string), width = 20)
squeeze <- function(x, width = NULL, ...) {
  # Hacky shortcut for zero-height corner case
  if (attr(x, "zero_height")) {
    return(new_colonnade_sqeezed(list(), x))
  }

  if (is.null(width)) {
    width <- get_width(x)
  }

  if (is.null(width)) {
    width <- getOption("width")
  }

  rowid <- attr(x, "rowid")
  if (is.null(rowid)) rowid_width <- 0
  else rowid_width <- max(get_widths(rowid)) + 1L

  col_widths <- colonnade_get_width(x, width, rowid_width)
  col_widths_show <- split(col_widths, factor(col_widths$tier != 0, levels = c(FALSE, TRUE)))
  col_widths_shown <- col_widths_show[["TRUE"]]
  col_widths_tiers <- split(col_widths_shown, col_widths_shown$tier)
  out <- map(col_widths_tiers, function(tier) {
    map2(x[tier$id], tier$width, pillar_format_parts)
  })

  if (!is.null(rowid)) {
    rowid_formatted <- pillar_format_parts(rowid, rowid_width - 1L)
    out <- map(out, function(x) c(list(rowid_formatted), x))
  }

  col_widths_extra <- col_widths_show[["FALSE"]]
  new_colonnade_sqeezed(out, x[col_widths_extra$id])
}

new_colonnade_sqeezed <- function(x, extra_cols) {
  structure(
    x,
    extra_cols = map_chr(extra_cols, pillar_format_abbrev),
    class = "squeezed_colonnade"
  )
}

#' @export
format.squeezed_colonnade <- function(x, ...) {
  formatted <- map(x, format_colonnade_tier)
  new_vertical(as.character(unlist(formatted)))
}

format_colonnade_tier <- function(x) {
  xt <- list(
    title = map(x, `[[`, "title_format"),
    type = map(x, `[[`, "type_format"),
    data = map(x, `[[`, "data_format")
  )

  c(
    invoke(paste, xt$title),
    style_type_header(invoke(paste, xt$type)),
    invoke(paste, xt$data)
  )
}

#' @export
print.squeezed_colonnade <- function(x, ...) {
  print(format(x, ...), ...)
  invisible(x)
}

# Method registration happens in .onLoad()
knit_print.squeezed_colonnade <- function(x, ...) {
  unlist(map(x, knit_print_squeezed_colonnade_tier))
}

knit_print_squeezed_colonnade_tier <- function(x) {
  header <- map_chr(x, `[[`, "title_format")
  col <- map(x, function(xx) c(xx[["type_format"]], xx[["data_format"]]))

  knitr::kable(as.data.frame(col), row.names = NA, col.names = header)
}

#' Retrieve information about columns that didn't fit the available width
#'
#' Formatting a [colonnade] object may lead to some columns being omitted
#' due to width restrictions. This method returns a character vector that
#' describes each of the omitted columns.
#' @param x The result of [squeeze()] on a [colonnade] object
#' @param ... Unused
#' @export
#' @examples
#' extra_cols(squeeze(colonnade(list(a = 1:3, b = 4:6), width = 8)))
extra_cols <- function(x, ...) {
  UseMethod("extra_cols")
}

#' @export
extra_cols.squeezed_colonnade <- function(x, ...) {
  attr(x, "extra_cols")
}

#' @export
format.colonnade <- function(x, ...) {
  format(squeeze(x, ...))
}

#' @export
print.colonnade <- function(x, ...) {
  print(format(x, ...))
}

#' @rdname colonnade
#' @usage NULL
#' @aliases NULL
colonnade_get_width <- function(x, width, rowid_width) {
  col_df <- data.frame(
    id = seq_along(x),
    max_widths = map_int(map(x, get_widths), max),
    min_widths = map_int(map(x, get_min_widths), max)
  )

  #' @details
  #' In a first pass, for each pillar it is decided in which tier it is shown,
  #' if at all, and how much horizontal space it may use (either its minimum
  #' or its maximum width). More than one tier may be created if
  #' `width > getOption("width")`, in this case each tier is at most
  #' `getOption("width")` characters wide.
  tier_widths <- get_tier_widths(width, length(x), rowid_width)
  col_widths_df <- colonnade_compute_tiered_col_widths_df(col_df, tier_widths)

  #' Remaining space is then distributed proportionally to pillars that do not
  #' use their desired width.
  colonnade_distribute_space_df(col_widths_df, tier_widths)
}

get_tier_widths <- function(width, ncol, rowid_width, tier_width = getOption("width")) {
  if (is.finite(width)) {
    pos <- c(
      seq(0, width - 1, by = tier_width),
      width
    )
  } else {
    pos <- seq(0, length.out = ncol + 1L, by = tier_width)
  }

  widths <- diff(pos) - rowid_width
  widths[widths >= 1]
}

#' @rdname colonnade
#' @usage NULL
#' @aliases NULL
colonnade_compute_tiered_col_widths_df <- function(col_df, tier_widths, fixed_tier_df = data.frame()) {
  if (nrow(col_df) == 0L) return(data.frame())

  tier_id <- max(c(fixed_tier_df$tier), 0L) + 1L
  tier_df <- colonnade_compute_col_widths_df(col_df, tier_widths[[1]], tier_id)

  #' @details
  #' For fitting pillars in one or more tiers, it is first attempted to fit all
  #' of them in the first tier.
  if (length(tier_widths) == 1 || all(tier_df$width >= tier_df$max_widths)) {
    #' If this succeeds (or if no more tiers are available), this fit is
    #' accepted.
    return(rbind(fixed_tier_df, tier_df))
  }

  #' Otherwise, an attempt is made to fit all remaining pillars in the remaining
  #' tiers (with a recursive call).
  all_tier_df <- colonnade_compute_tiered_col_widths_df(
    col_df[tier_df$tier == 0, ],
    tier_widths[-1],
    rbind(fixed_tier_df, slice(tier_df, tier_df$tier != 0))
  )

  #' If there still are pillars that don't fit, the minimum-width fit is accepted.
  if (!all_pillars_fit(all_tier_df)) return(all_tier_df)

  #'
  #' In case all remaining pillars fit all remaining tiers, a heuristic
  #' selects the optimal number of pillars in the first tier.
  first_expandable <- which(cumsum(tier_df$max_widths + 1L) > tier_widths[[1L]])[[1L]]
  last_fitting <- utils::tail(which(c(tier_df$tier, 0L) != 0L), 1L)
  #' The tier is grown starting with all pillars that are fitting with their
  #' desired width (at least one pillar will be used), and
  for (n_pillars_in_first_tier in seq2(max(first_expandable - 1L, 1L), last_fitting - 1L)) {
    #' attempts are made to fit the remaining pillars in the remaining tiers
    #' (with a recursive call for each attempt).
    all_tier_try_df <- colonnade_compute_tiered_col_widths_df(
      slice(col_df, seq2(n_pillars_in_first_tier + 1L, nrow(col_df))),
      tier_widths[-1],
      rbind(fixed_tier_df, slice(tier_df, seq_len(n_pillars_in_first_tier)))
    )

    #' The first successful fit
    if (all_pillars_fit(all_tier_try_df)) return(all_tier_try_df)
  }

  #' (or otherwise the initial minimum-width fit) is accepted.
  all_tier_df
}

all_pillars_fit <- function(tier_df) {
  rows <- nrow(tier_df)
  rows == 0 || tier_df$tier[[nrow(tier_df)]] != 0
}

#' @rdname colonnade
#' @usage NULL
#' @aliases NULL
colonnade_compute_col_widths_df <- function(col_df, width, tier_id = 1L) {
  col_widths <- colonnade_compute_col_widths(
    col_df$min_widths,
    col_df$max_widths,
    width
  )
  n_fitting_cols <- length(col_widths)
  col_widths <- c(col_widths, rep(0L, nrow(col_df) - length(col_widths)))

  col_df$width <- col_widths
  col_df$tier <- ifelse(seq_along(col_widths) > n_fitting_cols, 0L, tier_id)
  col_df
}

#' @rdname colonnade
#' @usage NULL
#' @aliases NULL
colonnade_compute_col_widths <- function(min_widths, max_widths, width) {
  #' @details
  #' For computing the pillar widths in a single tier, two cases are distinguished:
  #' 1. When taking the minimum width for each pillar (plus one inter-pillar
  #'    space), at least one pillar does not fit.
  cum_min_widths <- cumsum(min_widths + 1L)
  allowed_min <- which(cum_min_widths <= width)
  if (length(allowed_min) < length(min_widths)) {
    #'    In this case, the minimum width is assigned to all pillars that do fit,
    #'    the non-fitting pillars are stripped.
    col_widths <- min_widths[allowed_min]
  } else {
    #' 1. All pillars fit with their minimum width. In this case, starting at
    #'    the leftmost pillar, the maximum width is allocated to the pillars
    #'    until all available space is used.
    cum_max_widths <- cumsum(max_widths + 1L)
    rev_cum_rev_min_widths <- rev(cumsum(rev(min_widths) + 1L))

    allowed_max <- (cum_max_widths + c(rev_cum_rev_min_widths[-1L], 0L)) <= width
    col_widths <- ifelse(allowed_max, max_widths, min_widths)
  }

  col_widths
}

#' @rdname colonnade
#' @usage NULL
#' @aliases NULL
colonnade_distribute_space_df <- function(col_widths_df, tier_widths) {
  col_widths_split <- split(col_widths_df, col_widths_df$tier)
  if (any(col_widths_df$tier == 0)) tier_widths <- c(NA, tier_widths)
  tier_widths <- tier_widths[seq_along(col_widths_split)]
  col_widths_apply <- map2(col_widths_split, tier_widths, function(x, width) {
    x$width <- x$width + colonnade_distribute_space(x$width, x$max_widths, width)
    x
  })
  invoke(rbind, unname(col_widths_apply))
}

#' @rdname colonnade
#' @usage NULL
#' @aliases NULL
colonnade_distribute_space <- function(col_widths, max_widths, width) {
  if (any(is.na(col_widths))) return(col_widths)

  missing_space <- max_widths - col_widths
  # Shortcut to avoid division by zero
  if (all(missing_space == 0L)) return(rep_along(col_widths, 0L))

  #' @details
  #' The remaining space is distributed from left to right.
  #' Each column gains space proportional to the fraction of missing and
  #' remaining space,
  remaining_width <- min(width - sum(col_widths + 1L), sum(missing_space))
  added_space_prop <- missing_space / sum(missing_space) * remaining_width

  #' rounded down.
  added_space_ceil <- ceiling(added_space_prop)
  added_space_floor <- floor(added_space_prop)
  added_space_diff <- added_space_ceil - added_space_floor
  added_space <- ifelse(
    #' Any space remaining after rounding is distributed from left to right,
    #' one space per column.
    sum(added_space_floor) + cumsum(added_space_diff) <= remaining_width,
    added_space_ceil,
    added_space_floor
  )

  added_space
}
