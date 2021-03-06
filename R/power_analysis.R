# Runs Power Analysis for microbial abundances

#' Build a configuration for power analysis.
#'
#' This can be saved and passed on to others to ensure reproducibility.
#'
#' @param ... Any arguments are used to update the default configuration. See
#'  the example below. Optional.
#' @return A list with the parameters used in power analysis.
#' @export
#' @examples
#'  config <- config_power(fraction_differential = 0.1)
config_power <- config_builder(list(
    fraction_differential = 0.5,
    method = "permanova",
    type = "categorical",
    depth = "auto",
    n = ceiling(2 ^ seq(2, 7, length.out = 12) / 2) * 2,
    effect_size = seq(0, 0.9, by = 0.1),
    threads = getOption("mc.cores", 1),
    pval = 0.05,
    n_power = 8,
    n_groups = 8,
    min_mu = 1e-3,
    min_mu_over_phi = 1
))

memory_use <- function(config, n_taxa) {
    size <- 8 * max(config$n) * config$n_power * config$n_groups *
            n_taxa * config$threads
    class(size) <- "object_size"
    return(size)
}

get_corncob_pars <- function(ps, threads = getOption("mc.cores", 1)) {
    if (!requireNamespace("corncob", quietly = TRUE)) {
        stop("Power Analysis requires `corncob` to be installed.")
    }

    clean <- corncob::clean_taxa_names(ps)
    tnames <- attr(clean, "original_names")
    names(tnames) <- taxa_names(clean)

    apfun <- parse_threads(threads)
    pars <- apfun(taxa_names(clean), function(taxon) {
        r <- tryCatch(corncob::bbdml(
            formula = reformulate("1", taxon),
            phi.formula = ~ 1,
            data = clean),
            error = function(e) list(mu.resp = NA, phi.resp = NA))
        cn <- otu_table(clean)[, taxon]
        data.table(mu = r$mu.resp[1], phi = r$phi.resp[1],
                   mean_reads = mean(cn), min_reads = min(cn),
                   max_reads = max(cn), prevalence = mean(cn > 0),
                   taxon = taxon)
    }) %>% rbindlist()
    pars[, taxon := tnames[taxon]]
    setkey(pars, "taxon")

    return(pars)
}

#' Plot the Betabinomial fits for all taxa in a phyloseq object
#'
#' @param ps A phyloseq object containing data for a reference experiment.
#'  This should assume absence of any differential effect (all variation is
#'  random).
#' @param bins number of bins to use for histograms. Defaults to Sturges rule.
#' @return A ggplot2 plot object shwoing the fits for each taxon.
#' @export
plot_bb_fits <- function(ps, bins = NULL) {
    ps <- rarefy_even_depth(ps, min(sample_sums(ps), 10000))
    pars <- get_corncob_pars(ps)
    cns <- as(otu_table(ps), "matrix") %>%
           as.data.table() %>%
           melt(value.name = "count", variable.name = "taxon",
                measure.vars = taxa_names(ps)) %>%
           suppressWarnings()
    if (is.null(bins)) {
        bins <- (log2(nsamples(ps)) + 1) %>% ceiling()
    }

    dens <- pars[, .(
        mu, phi,
        count = seq(min_reads, max_reads, by = 1),
        d = VGAM::dbetabinom(seq(min_reads, max_reads, by = 1),
                             sample_sums(ps)[1], mu, phi)
        ), by = "taxon"]
    pl <- ggplot(cns, aes(x = count)) +
        geom_histogram(aes(y = stat(density)), bins = bins) +
        geom_line(data = dens, aes(x = count, y = d), size = 1,
                  color = "royalblue") +
        facet_wrap(~ taxon, scales = "free") +
        labs(x = "#reads", y = "density")
    return(pl)
}

sample_corncob <- function(pars, sig_taxa, type, scale,
                           size = 10000, reps = 1000) {
    n <- length(scale)
    last <- pars[, sort(unique(taxon))[uniqueN(taxon)]]
    p <- sapply(pars$taxon, function(taxon) {
        if (taxon %in% sig_taxa) {
            p <- rep(pars[taxon, mu] * scale, reps)
        } else {
            p <- rep(pars[taxon, mu], length(scale) * reps)
        }
    })
    colnames(p) <- pars$taxon
    p[, last] <- pars[, sum(mu)] - rowSums(p[, 1:(ncol(p) - 1)])
    p <- sapply(1:ncol(p), function(i) {
        taxon <- colnames(p)[i]
        VGAM::rbetabinom(n = n * reps, size = size, prob = p[, i],
                         rho = pars[taxon, phi])

    })
    colnames(p) <- pars$taxon

    snames <- paste0("sample_", 1:n)
    p <- lapply(1:reps, function(i) {
        x <- p[(1 + (i - 1) * n) : (i * n), ]
        rownames(x) <- snames
        return(x)
    })

    return(p)
}

mwtest <- function(counts, taxa) {
    first <- 1:(nrow(counts) / 2)
    second <- (nrow(counts) / 2) : nrow(counts)
    p <- counts / rowSums(counts)
    res <- lapply(taxa, function(ta) {
        ctrl <- p[first, ta] + 0.5
        case <- p[second, ta] + 0.5
        te <- suppressWarnings(
            wilcox.test(ctrl, case))
        data.table(taxa = ta, pval = te$p.value)
    }) %>% rbindlist()
    res[, "pval" := p.adjust(pval, method = "fdr")]
    res[is.na(pval), "pval" := 1]
    return(res)
}

corncob_test <- function(counts, v, sig_taxa) {
    sdata <- data.frame(v = v)
    rownames(sdata) <- rownames(counts)
    taxa <- matrix(colnames(counts), ncol = 1)
    colnames(taxa) <- "taxon"
    rownames(taxa) <- colnames(counts)
    ps <- phyloseq(
        otu_table(counts, taxa_are_rows = FALSE),
        tax_table(taxa),
        sample_data(sdata)
    )
    res <- lapply(rownames(taxa), function(ta) {
        p <- tryCatch(
            corncob::lrtest(
                corncob::bbdml(reformulate("v", ta), ~ 1, ps),
                corncob::bbdml(reformulate("1", ta), ~ 1, ps)
            ),
            error = function(e) 1,
            warning = function(w) 1
        )
        data.table(taxa = ta, pval = p)
    }) %>% rbindlist()
    res[, "tp" := !is.na(pval) & taxa %in% sig_taxa]
    res[is.na(pval), "pval" := 1]
    res[, pval := p.adjust(pval, method = "fdr")]
    return(res)
}

#' Run a power analysis for microbe abundances from a reference sample.
#'
#' @param ps A phyloseq object containing data for a reference experiment.
#'  This should assume absence of any differential effect (all variation is
#'  random).
#' @param ... A configuration as described by \code{\link{config_power}}.
#' @return An artifact with an entry `power` that quantifies the power
#'  over many n and effect size.
#' @export
power_analysis <- function(ps, ...) {
    config <- config_parser(list(...), config_power)
    apfun <- parse_threads(config$threads)
    if (config$depth == "auto") {
        if ("data.table" %in% class(ps)) {
            stop("If passing parameters you need to specify depth.")
        }
        config$depth <- sample_sums(ps) %>% median() %>% ceiling()
        flog.info("Using median depth from reference data (%d).",
                  config$depth)
    }
    if ("data.table" %in% class(ps)) {
        pars <- ps
        n_taxa <- nrow(pars)
        setkey(pars, "taxon")
    } else {
        flog.info("Estimating corncob model parameters for %d taxa...",
                  ntaxa(ps))
        pars <- get_corncob_pars(ps, config$threads)
        pars <- pars[
            !is.na(mu) &
            mu > config$min_mu &
            mu / phi > config$min_mu_over_phi
        ]
        n_taxa <- ntaxa(ps)
        ps <- prune_taxa(pars$taxon, ps)
    }

    flog.info(paste0(
        "Succesfully estimated parameters for %d/%d taxa. ",
        "<mu> = %.3g, <phi> = %.3g."),
        nrow(pars), n_taxa, pars[, mean(mu)], pars[, mean(phi)])

    comb <- expand.grid(list(n = config$n,
                             effect_size = config$effect_size))
    fraction <- config$fraction_differential

    last <- pars[, sort(unique(taxon))[uniqueN(taxon)]]
    taxa <- pars[taxon != last, taxon]
    sig_taxa <- sample(taxa, fraction * nrow(pars) - 1)
    sig_taxa <- c(sig_taxa, last)

    flog.info(paste("Estimating power for %d n/effect combinations.",
                    "%d/%d taxa are truly differential."), nrow(comb),
                    floor(fraction * nrow(pars)), nrow(pars))
    flog.info("Will need at least %s of memory.",
              memory_use(config, nrow(pars)) %>% format(unit = "auto"))
    if (config$method == "permanova") {
        if (!requireNamespace("vegan", quietly = TRUE)) {
            stop("PERMANOVA requires `vegan` to be installed.")
        }
        power <- apfun(1:nrow(comb), function(i) {
            co <- as.numeric(comb[i, ])
            if (config$type == "categorical") {
                scale <- c(rep(1, co[1] / 2), rep(1 - co[2], co[1] / 2))
                v <- c(rep("control", co[1] / 2), rep("changed", co[1] / 2))
            } else {
                v <- seq(0, 1, length.out = co[1])
                scale <- 1 - v * co[2]

            }
            counts <- sample_corncob(pars, sig_taxa, config$type, scale,
                config$depth, config$n_power * config$n_groups)
            p <- lapply(counts, function(co) {
                res <- suppressMessages(
                    vegan::adonis2(co ~ v, data = data.frame(v = v)))
                data.table(r2 = res[1, "R2"], pval = res[1, "Pr(>F)"])
            }) %>% rbindlist()
            p[, "replicate" := rep(1:config$n_groups, config$n_power)]
            p <- p[, .(n = co[1], effect = co[2], r2 = mean(r2),
                       power = mean(pval < config$pval)), by = "replicate"]
            p <- p[, .(n = co[1], effect = co[2], r2 = mean(r2),
                       r2_sd = sd(r2),
                       power = mean(power), power_sd = sd(power))]
            flog.info(paste("Power for n=%d and effect=%.3g is %.3g ",
                            "(reported R2=%.3g)."),
                      as.integer(co[1]), co[2], p$power, p$r2)
            return(p)
        })
    } else if (config$method == "corncob") {
        power <- apfun(1:nrow(comb), function(i) {
            co <- as.numeric(comb[i, ])
            if (config$type == "categorical") {
                scale <- c(rep(1, co[1] / 2), rep(1 - co[2], co[1] / 2))
                v <- c(rep("control", co[1] / 2), rep("changed", co[1] / 2))
            } else {
                v <- seq(0, 1, length.out = co[1])
                scale <- 1 - v * co[2]

            }
            counts <- sample_corncob(pars, sig_taxa, config$type, scale,
                config$depth, config$n_power * config$n_groups)
            if (config$type == "categorical") {
                v <- factor(v)
            }
            p <- lapply(counts, function(cn) {
                corncob_test(cn, v, sig_taxa)
            }) %>% rbindlist()
            p[, "replicate" := rep(1:config$n_groups, config$n_power),
              by = "taxa"]
            p <- p[, .(power = mean(pval[tp] < config$pval),
                       fdr = (
                           sum(pval[!taxa %in% sig_taxa] < config$pval) /
                           sum(pval < config$pval))
                      ),
                      by = "replicate"]
            p[is.finite(fdr) == FALSE, "fdr" := 0]
            p <- p[, .(n = co[1], effect = co[2],
                       mu = pars[, mean(mu)], phi = pars[, mean(phi)],
                       mean_reads = pars[, mean(mean_reads)],
                       prevalence = pars[, mean(prevalence)],
                       power = mean(power), power_sd = sd(power),
                       fdr = mean(fdr), fdr_sd = sd(fdr)),
                  ]
            flog.info("Power for n=%d and effect=%.3g is %.3g. FDR is %.3g.",
                      as.integer(co[1]), co[2], p$power, p$fdr)
            return(p)
        })
    } else if (config$type == "categorical") {
        power <- apfun(1:nrow(comb), function(i) {
            co <- as.numeric(comb[i, ])
            scale <- c(rep(1, co[1] / 2), rep(1 - co[2], co[1] / 2))
            counts <- sample_corncob(pars, sig_taxa, config$type, scale,
                config$depth, config$n_power * config$n_groups)
            p <- lapply(counts, function(co) {
                mwtest(co, colnames(co))
            }) %>% rbindlist()
            p[, "replicate" := rep(1:config$n_groups, config$n_power),
              by = "taxa"]
            p <- p[, .(power = mean(pval[taxa %in% sig_taxa] < config$pval),
                       fdr = (
                           sum(pval[!taxa %in% sig_taxa] < config$pval) /
                           sum(pval < config$pval))
                      ),
                      by = "replicate"]
            p[is.finite(fdr) == FALSE, "fdr" := 0]
            p <- p[, .(n = co[1], effect = co[2],
                       mu = pars[, mean(mu)], phi = pars[, mean(phi)],
                       mean_reads = pars[, mean(mean_reads)],
                       prevalence = pars[, mean(prevalence)],
                       power = mean(power), power_sd = sd(power),
                       fdr = mean(fdr), fdr_sd = sd(fdr)),
                  ]
            flog.info("Power for n=%d and effect=%.3g is %.3g. FDR is %.3g.",
                      as.integer(co[1]), co[2], p$power, p$fdr)
            return(p)
        })
    }

    power <- rbindlist(power)
    if (config$method == "permanova") {
        power[, "asym_r2" := r2[n == max(n)], by = "effect"]
        power[, "asym_r2_sd" := r2_sd[n == max(n)], by = "effect"]
        power[, "fdr" := mean(power[effect == 0]) / mean(power), by = "n"]
        power[, "fdr_sd" := mean(power_sd[effect == 0]) / mean(power), by = "n"]
    }
    power[effect == 0, "fdr" := NA]
    power[effect == 0, "fdr_sd" := NA]

    artifact <- list(
        power = power,
        steps = c("power_analysis"),
        parameters = pars,
        phyloseq = ps
    )
    return(artifact)
}
