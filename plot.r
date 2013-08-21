# Also draws 95% confidence interval
PlotAcfExperiment <- function(filename, my_title) {
	tab = data.matrix(read.csv(paste(filename, ".csv", sep=""), header=FALSE))
	means = rowMeans(tab)
	sds = apply(tab, 1, sd)
	err = apply(tab, 1, function(row) { qnorm(.975, sd=sd(row)) / sqrt(length(row))})

	png(paste(filename, ".png", sep=""))

	plot(1:1000, means, type="l", ylim=c(min(means)-.1,1), ylab="Autocorrelation", xlab="Lag")
	title(my_title)
	lines(means+err, col=2, lty=3)
	lines(means-err, col=2, lty=3)

	dev.off()
}

PlotAcaExperiment <- function(filename, my_title) {
	tab = data.matrix(read.csv(paste(filename, ".csv", sep=""), header=FALSE))
	means = rowMeans(tab)
	sds = apply(tab, 1, sd)
	err = apply(tab, 1, function(row) { qnorm(.975, sd=sd(row)) / sqrt(length(row))})

	png(paste(filename, ".png", sep=""))

	plot(1:10*10, means, type="l", ylim=c(0,250),
		ylab="Autocorrelation area", xlab="Number of sites")
	title(my_title)
	lines(1:10*10, means+err, col=2, lty=3)
	lines(1:10*10, means-err, col=2, lty=3)
	dev.off()
}

PlotAcfExperiment("acf_normal", "ACF Normal, 50 sites, 1000 samples, 20 runs")
PlotAcfExperiment("acf_global", "ACF Global tempering, 50 sites, 1000 samples, 20 runs")
PlotAcfExperiment("acf_local", "ACF Local tempering, 50 sites, 1000 samples, 20 runs")

PlotAcaExperiment("aca_normal", "ACA Normal, 10-100 sites, 1000 samples, 10 runs")
PlotAcaExperiment("aca_global", "ACA Global tempering, 10-100 sites, 1000 samples, 10 runs")
PlotAcaExperiment("aca_local", "ACA Local tempering, 10-100 sites, 1000 samples, 10 runs")

png(paste("acf_means.png", sep=""))
acf_normal_means = rowMeans(read.csv("acf_normal.csv", header=FALSE))
acf_global_means = rowMeans(read.csv("acf_global.csv", header=FALSE))
acf_local_means = rowMeans(read.csv("acf_local.csv", header=FALSE))
plot(1:1000, acf_normal_means, type="l", ylim=c(min(means)-.1,1), ylab="Autocorrelation", xlab="Lag", col=2)
title("ACF, 50 sites, 1000 samples, 20 runs")
lines(acf_global_means, col=3)
lines(acf_local_means, col=4)
legend(x=.9, y=800, legend=c("Normal", "Global", "Local"), col=c(2, 3, 4), lty=c(1, 1, 1))
dev.off()

png(paste("aca_means.png", sep=""))
aca_normal_means = rowMeans(read.csv("aca_normal.csv", header=FALSE))
aca_global_means = rowMeans(read.csv("aca_global.csv", header=FALSE))
aca_local_means = rowMeans(read.csv("aca_local.csv", header=FALSE))
plot(1:10*10, aca_normal_means, type="l", ylim=c(0,250), ylab="Autocorrelation area", xlab="Lag", col=2)
title("ACA, 10-100 sites, 1000 samples, 10 runs")
lines(1:10*10, aca_global_means, col=3)
lines(1:10*10, aca_local_means, col=4)
legend(x=80, y=50, legend=c("Normal", "Global", "Local"), col=c(2, 3, 4), lty=c(1, 1, 1))
dev.off()