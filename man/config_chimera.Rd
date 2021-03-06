% Generated by roxygen2: do not edit by hand
% Please edit documentation in R/chimera.R
\name{config_chimera}
\alias{config_chimera}
\title{Build a configuration for chimera removal.}
\usage{
config_chimera(...)
}
\arguments{
\item{...}{Any arguments are used to update the default configuration. See
the example below. Optional.}
}
\value{
A list with the parameters used in the DADA2 workflow.
}
\description{
This can be saved and passed on to others to ensure reproducibility.
}
\examples{
 config <- config_preprocess(truncLen = c(240, 250))
}
