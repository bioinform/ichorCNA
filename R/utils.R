# file:   utils.R
# author: Gavin Ha, Ph.D.
#         Fred Hutchinson Cancer Research Center
# contact: <gha@fredhutch.org>
# website: https://GavinHaLab.org
#
# author: Justin Rhoades, Broad Institute
#
# ichorCNA website: https://github.com/GavinHaLab/ichorCNA
# date:   January 6, 2020
#
# description: Hidden Markov model (HMM) to analyze Ultra-low pass whole genome sequencing (ULP-WGS) data.
# This script is the main script to run the HMM.

####################################
##### FUNCTION TO FILTER CHRS ######
####################################
# updated for GRanges #
keepChr <- function(tumour_reads, chrs = c(1:22,"X","Y")){	
	tumour_reads <- keepSeqlevels(tumour_reads, chrs, pruning.mode="tidy")
	sortSeqlevels(tumour_reads)
	return(sort(tumour_reads))
}

filterEmptyChr <- function(gr){
	require(plyr)
	ind <- daply(as.data.frame(gr), .variables = "seqnames", .fun = function(x){
	  rowInd <- apply(x[, 6:ncol(x), drop = FALSE], 1, function(y){
	    sum(is.na(y)) == length(y)
	  })
	  sum(rowInd) == nrow(x)
	})	
	return(keepSeqlevels(gr, value = names(which(!ind))))
}

####################################
##### FUNCTION GET SEQINFO ######
####################################
getSeqInfo <- function(genomeBuild = "hg19", genomeStyle = "NCBI", chrs = c(1:22, "X")){
	bsg <- paste0("BSgenome.Hsapiens.UCSC.", genomeBuild)
	if (!require(bsg, character.only=TRUE, quietly=TRUE, warn.conflicts=FALSE)) {
		seqinfo <- Seqinfo(genome=genomeBuild)
	} else {
		seqinfo <- seqinfo(get(bsg))
	}
	chrs <- as.character(chrs)
	seqlevelsStyle(seqinfo) <- genomeStyle
	seqlevelsStyle(chrs) <- genomeStyle
	seqinfo <- keepSeqlevels(seqinfo, value = chrs)
	#seqinfo <- cbind(seqnames = seqnames(seqinfo), as.data.frame(seqinfo))
	return(seqinfo)	
}

##################################################
##### FUNCTION TO FILTER CENTROMERE REGIONS ######
##################################################
excludeCentromere <- function(x, centromere, flankLength = 0, genomeStyle = "NCBI"){
	require(GenomeInfoDb)
	colnames(centromere)[1:3] <- c("seqnames","start","end")
	centromere$start <- centromere$start - flankLength
	centromere$end <- centromere$end + flankLength
	centromere <- as(centromere, "GRanges")
	seqlevelsStyle(centromere) <- genomeStyle
	centromere <- sort(centromere)	
	hits <- findOverlaps(query = x, subject = centromere)
	ind <- queryHits(hits)
	message("Removed ", length(ind), " bins near centromeres.")
	if (length(ind) > 0){
		x <- x[-ind, ]
	}
	return(x)
}

##################################################
##### FUNCTION TO USE NCBI CHROMOSOME NAMES ######
##################################################
## deprecated ##
setGenomeStyle <- function(x, genomeStyle = "NCBI", species = "Homo_sapiens"){
        require(GenomeInfoDb)
        #chrs <- genomeStyles(species)[c("NCBI","UCSC")]
        if (!genomeStyle %in% seqlevelsStyle(as.character(x))){
        x <- suppressWarnings(mapSeqlevels(as.character(x),
                                        genomeStyle, drop = FALSE)[1,])
    }

    autoSexMChr <- extractSeqlevelsByGroup(species = species,
                                style = genomeStyle, group = "all")
    x <- x[x %in% autoSexMChr]
    return(x)
}

wigToGRanges <- function(wigfile, verbose = TRUE){
  output <- tryCatch({
    input <- readLines(wigfile, warn = FALSE)
    breaks <- c(grep("fixedStep", input), length(input) + 1)
    temp <- NULL
    span <- NULL
    for (i in 1:(length(breaks) - 1)) {
      data_range <- (breaks[i] + 1):(breaks[i + 1] - 1)
      track_info <- input[breaks[i]]
      if (verbose) { message(paste("Parsing:", track_info)) }
      tokens <- strsplit(
        sub("fixedStep chrom=(\\S+) start=(\\d+) step=(\\d+) span=(\\d+)",
            "\\1 \\2 \\3 \\4", track_info, perl = TRUE), " ")[[1]]
      span <- as.integer(tokens[4])
      chr <- rep.int(tokens[1], length(data_range))
      pos <- seq(from = as.integer(tokens[2]), by = as.integer(tokens[3]),
                 length.out = length(data_range))
      val <- as.numeric(input[data_range])
      temp <- c(temp, list(data.frame(chr, pos, val)))
    }
    if (verbose) { message("Sorting by decreasing chromosome size") }
    lengths <- as.integer(lapply(temp, nrow))
    temp <- temp[order(lengths, decreasing = TRUE)]
    temp = do.call("rbind", temp)
    output <- GenomicRanges::GRanges(ranges = IRanges(start = temp$pos, width = span),
                         seqnames = temp$chr, value = temp$val)
    return(output)
  }, error = function(e){
    message("wigToGRanges: WIG file '", wigfile, "' not found.")
    return(NULL)
  })
  return(output)
}


loadReadCountsFromWig <- function(counts, chrs = c(1:22, "X", "Y"), gc = NULL, map = NULL, repTime = NULL, centromere = NULL, flankLength = 100000, targetedSequences = NULL, genomeStyle = "NCBI", applyCorrection = TRUE, mapScoreThres = 0.9, chrNormalize = c(1:22, "X", "Y"), fracReadsInChrYForMale = 0.002, chrXMedianForMale = -0.5, useChrY = TRUE){
	require(HMMcopy)
	require(GenomeInfoDb)
	seqlevelsStyle(counts) <- genomeStyle
	counts.raw <- counts	
	counts <- keepChr(counts, chrs)
	
	if (!is.null(gc)){ 
		seqlevelsStyle(gc) <- genomeStyle
		tryCatch({
		  counts$gc <- keepChr(gc, chrs)$value
		}, error = function(e){
		  stop("loadReadCountsFromWig: Number of bins in gc different than input wig.")
		})
	}
	if (!is.null(map)){ 
		seqlevelsStyle(map) <- genomeStyle
		tryCatch({
		  counts$map <- keepChr(map, chrs)$value
		}, error = function(e){
		  stop("loadReadCountsFromWig: Number of bins in map different than input wig.")
		})
	}
	if (!is.null(repTime)){
	  seqlevelsStyle(repTime) <- genomeStyle
	  tryCatch({
	    counts$repTime <- keepChr(repTime, chrs)$value
	    #counts$repTime <- 1 / (1 + exp(-1 * counts$repTime)) # logistic transformation
	    #counts$repTime <- counts$repTime # use the inverse
	  }, error = function(e){
	    stop("loadReadCountsFromWig: Number of bins in repTime different than input wig.")
	  })
	}
	colnames(values(counts))[1] <- c("reads")
	
	# remove centromeres
	if (!is.null(centromere)){ 
		counts <- excludeCentromere(counts, centromere, flankLength = flankLength, genomeStyle=genomeStyle)
	}
	# keep targeted sequences
	if (!is.null(targetedSequences)){
		colnames(targetedSequences)[1:3] <- c("chr", "start", "end")
		targetedSequences.GR <- as(targetedSequences, "GRanges")
		seqlevelsStyle(targetedSequences.GR) <- genomeStyle
		countsExons <- filterByTargetedSequences(counts, targetedSequences.GR)
		counts <- counts[countsExons$ix,]
	}
	gender <- NULL
	gc.fit <- NULL
	map.fit <- NULL
	rep.fit <- NULL
	if (applyCorrection){
		## correct read counts ##
		cor.counts <- correctReadCounts(counts, mappability = 0, chrNormalize = chrNormalize)
		if (!is.null(map)) {
		  ## filter bins by mappability
		  cor.counts$cor <- filterByMappabilityScore(cor.counts$cor, map=map, mapScoreThres = mapScoreThres)
		}
		counts <- cor.counts$cor
		gc.fit <- cor.counts$gc.fit
		map.fit <- cor.counts$map.fit
		rep.fit <- cor.counts$rep.fit
		## get gender ##
		gender <- getGender(counts.raw, counts, gc, map, fracReadsInChrYForMale = fracReadsInChrYForMale, 
							chrXMedianForMale = chrXMedianForMale, useChrY = useChrY,
							centromere=centromere, flankLength=flankLength, targetedSequences = targetedSequences,
							genomeStyle = genomeStyle)
    }
  return(list(counts = counts, gender = gender, gc.fit = gc.fit, map.fit = map.fit, rep.fit = rep.fit))
}

filterByMappabilityScore <- function(counts, map, mapScoreThres = 0.9){
	message("Filtering low uniqueness regions with mappability score < ", mapScoreThres)
	counts <- counts[counts$map >= mapScoreThres, ]
	return(counts)
}

filterByTargetedSequences <- function(counts, targetedSequences){
 ### for targeted sequencing (e.g.  exome capture),
    ### ignore bins with 0 for both tumour and normal
    ### targetedSequence = GRanges object
    ### containing list of targeted regions to consider;
    ### 3 columns: chr, start, end
					
	hits <- findOverlaps(query = counts, subject = targetedSequences)
	keepInd <- unique(queryHits(hits))    

	return(list(counts=counts, ix=keepInd))
}

selectFemaleChrXSolution <- function(){
	
}

##################################################
### FUNCTION TO DETERMINE GENDER #################
##################################################
getGender <- function(rawReads, normReads, gc, map, fracReadsInChrYForMale = 0.002, chrXMedianForMale = -0.5, useChrY = TRUE,
					  centromere=NULL, flankLength=1e5, targetedSequences=NULL, genomeStyle="NCBI"){
	chrXStr <- grep("X", runValue(seqnames(normReads)), value = TRUE)
	chrYStr <- grep("Y", runValue(seqnames(rawReads)), value = TRUE)
	chrXInd <- as.character(seqnames(normReads)) == chrXStr
	if (sum(chrXInd) > 1){ ## if no X 
		chrXMedian <- median(normReads[chrXInd, ]$copy, na.rm = TRUE)
		# proportion of reads in chrY #
		tumY <- loadReadCountsFromWig(rawReads, chrs=chrYStr, genomeStyle=genomeStyle,
				gc=gc, map=map, applyCorrection = FALSE, centromere=centromere, flankLength=flankLength, 
				targetedSequences=targetedSequences)$counts
		chrYCov <- sum(tumY$reads) / sum(rawReads$value)
		if (chrXMedian < chrXMedianForMale){
			if (useChrY && (chrYCov < fracReadsInChrYForMale)){ #trumps chrX if using chrY
					gender <- "female"  
			}else{
				gender <- "male" # satisfies decreased chrX log ratio and/or increased chrY coverage
			}
		}else{
			gender <- "female" # chrX is provided but does not satisfies male critera
		}
	}else{
		gender <- "unknown" # chrX is not provided
		chrYCov <- NA
		chrXMedian <- NULL
	}
	return(list(gender=gender, chrYCovRatio=chrYCov, chrXMedian=chrXMedian))
}
	
	
normalizeByPanelOrMatchedNormal <- function(tumour_copy, chrs = c(1:22, "X", "Y"), 
      normal_panel = NULL, normal_copy = NULL, gender = "female", normalizeMaleX = FALSE){
    genomeStyle <- seqlevelsStyle(tumour_copy)[1]
    seqlevelsStyle(chrs) <- genomeStyle
 	### COMPUTE LOG RATIO FROM MATCHED NORMAL OR PANEL AND HANDLE CHRX ###
	chrXInd <- grep("X", as.character(seqnames(tumour_copy)))
	chrXMedian <- median(tumour_copy[chrXInd, ]$copy, na.rm = TRUE)

	# matched normal and panel and male, then compute normalized chrX median 
	# if (!is.null(normal_copy) && !is.null(normal_panel) && gender=="male"){
	# 		message("Normalizing by matched normal for ChrX")
	# 		chrX.MNnorm <- tumour_copy$copy[chrXInd] - normal_copy$copy[chrXInd]
	# 		chrXMedian.MNnorm <- median(chrX.MNnorm, na.rm = TRUE)
	# }
	# MATCHED NORMAL, normalize by matched normal
	# if both normal and panel, then this step is the second normalization
	if (!is.null(normal_copy)){
		message("Normalizing Tumour by Normal")
		tumour_copy$copy <- tumour_copy$copy - normal_copy$copy
		rm(normal_copy)
	}else if (is.null(normal_copy) && gender == "male" && normalizeMaleX){
		# if male, and no matched normal, then just normalize chrX to median 
		tumour_copy$copy[chrXInd] <- tumour_copy$copy[chrXInd] - chrXMedian
	}
	# PANEL, then normalize by panel instead of matched normal 
	if (!is.null(normal_panel)){
		message("Normalizing Tumour by Panel of Normals (PoN)")
		## load in IRanges object, then convert to GRanges
		panel <- readRDS(normal_panel)
		seqlevelsStyle(panel) <- genomeStyle
		panel <- keepChr(panel, chr = chrs)
		chrXInd.panel <- grep("X", as.character(seqnames(panel)))
        # intersect bins in sample and panel
        hits <- findOverlaps(query = tumour_copy, subject = panel, type="equal")
        #tumour_copy <- tumour_copy[queryHits(hits),]
        #panel <- panel[subjectHits(hits),]
        #if (!is.null(normal_copy)){ # if matched normal provided, then subset it too
        #	normal_copy <- normal_copy[queryHits(hits),]
        #}
        ### Normalize by panel median
        if (normalizeMaleX == FALSE && gender == "male"){  # do not normalize chrX with PoN
        	autoChrInd.tum <- setdiff(queryHits(hits), chrXInd)
        	autoChrInd.panel <- setdiff(subjectHits(hits), chrXInd.panel)
			tumour_copy$copy[chrXInd.panel] <- tumour_copy$copy[chrXInd.panel] - panel$Median[chrXInd.panel]
		}else { # female OR normalizeMaleX - normalize chrX with PoN
			tumour_copy$copy[queryHits(hits)] <- tumour_copy$copy[queryHits(hits)] - 
				panel$Median[subjectHits(hits)]
		}
	}
	
	# }else if (gender == "male" && exists("chrXMedian.MNnorm")){
	# 	# if male, then shift chrX by +chrXMedian.MNnorm
	# 	# only need if matched normal doesn't 
	# 	tumour_copy$copy[chrXInd] <- tumour_copy$copy[chrXInd] + chrXMedian.MNnorm
	# }
	
	return(tumour_copy)
}

##################################################
###### FUNCTION TO CORRECT GC/MAP BIASES ########
##################################################
correctReadCounts <- function(x, chrNormalize = c(1:22), mappability = 0.9, samplesize = 50000,
    verbose = TRUE) {
  if (length(x$reads) == 0 | length(x$gc) == 0) {
    stop("Missing one of required columns: reads, gc")
  }
  chrInd <- as.character(seqnames(x)) %in% chrNormalize
  if(verbose) { message("Applying filter on data...") }
  x$valid <- TRUE
  x$valid[x$reads <= 0 | x$gc < 0] <- FALSE
  x$ideal <- TRUE
  routlier <- 0.01
  range <- quantile(x$reads[x$valid & chrInd], prob = c(0, 1 - routlier), na.rm = TRUE)
  doutlier <- 0.001
  domain <- quantile(x$gc[x$valid & chrInd], prob = c(doutlier, 1 - doutlier), na.rm = TRUE)
  if (length(x$map) != 0) {
    x$ideal[!x$valid | x$map < mappability | x$reads <= range[1] |
      x$reads > range[2] | x$gc < domain[1] | x$gc > domain[2]] <- FALSE
  } else {
    x$ideal[!x$valid | x$reads <= range[1] |
      x$reads > range[2] | x$gc < domain[1] | x$gc > domain[2]] <- FALSE
  }

  if (verbose) { message("Correcting for GC bias...") }
  set <- which(x$ideal & chrInd)
  select <- sample(set, min(length(set), samplesize))
  rough <- loess(x$reads[select] ~ x$gc[select], span = 0.03)
  i <- seq(0, 1, by = 0.001)
  final.gc <- loess(predict(rough, i) ~ i, span = 0.3)
  x$cor.gc <- x$reads / predict(final.gc, x$gc)

  final.map <- NULL
  if (length(x$map) != 0) {
    if (verbose) { message("Correcting for mappability bias...") }
    coutlier <- 0.01
    range <- quantile(x$cor.gc[which(x$valid & chrInd)], prob = c(0, 1 - coutlier), na.rm = TRUE)
    set <- which(x$cor.gc < range[2] & chrInd)
    select <- sample(set, min(length(set), samplesize))
    final.map <- approxfun(lowess(x$map[select], x$cor.gc[select]))
    x$cor.map <- x$cor.gc / final.map(x$map)
  } else {
    x$cor.map <- x$cor.gc
  }
  
  final.rep <- NULL
  if (length(x$repTime) != 0){
    if (verbose) { message("Correcting for replication timing bias...") }
    coutlier <- 0.01
    range <- quantile(x$cor.map[which(x$valid & chrInd)], prob = c(0, 1 - coutlier), na.rm = TRUE)
    domain.rep <- quantile(x$repTime[x$valid & chrInd], prob = c(doutlier, 1 - doutlier), na.rm = TRUE)
    set <- which(x$cor.map < range[2] & chrInd)
    select <- sample(set, min(length(set), samplesize))
    rough <- loess(x$cor.map[select] ~ x$repTime[select], span = 0.03)
    i <- seq(domain.rep[1], domain.rep[2], by = 0.001)
    final.rep <- loess(predict(rough, i) ~ i, span = 0.3)
    x$cor.rep <- x$cor.map / predict(final.rep, x$repTime)
  }else{
    x$cor.rep <- x$cor.map
  }
  x$copy <- x$cor.rep
  x$copy[x$copy <= 0] = NA
  x$copy <- log(x$copy, 2)
  return(list(cor=x, gc.fit = final.gc, map.fit = final.map, rep.fit = final.rep))
}

## Recompute integer CN for high-level amplifications ##
## compute logR-corrected copy number ##
correctIntegerCN <- function(cn, segs, callColName = "event", 
		purity, ploidy, cellPrev, maxCNtoCorrect.autosomes = NULL, 
		maxCNtoCorrect.X = NULL, correctHOMD = TRUE, correctWholeChrXForMales = FALSE,
		minPurityToCorrect = 0.2, gender = "male", chrs = c(1:22, "X")){
	names <- c("HOMD","HETD","NEUT","GAIN","AMP","HLAMP", rep("HLAMP", 1000))

	## set up chromosome style
	autosomeStr <- grep("X|Y", chrs, value=TRUE, invert=TRUE)
	chrXStr <- grep("X", chrs, value=TRUE)
	
	if (is.null(maxCNtoCorrect.autosomes)){
		maxCNtoCorrect.autosomes <- max(segs[segs$chr %in% autosomeStr, "copy.number"], na.rm = TRUE)
	}
	if (is.null(maxCNtoCorrect.X) & gender == "female" & length(chrXStr) > 0){
		maxCNtoCorrect.X <- max(segs[segs$chr == chrXStr, "copy.number"], na.rm=TRUE)
	}
	## correct log ratio and compute corrected CN
	cellPrev.seg <- rep(1, nrow(segs))
	cellPrev.seg[as.logical(segs$subclone.status)] <- 1 #cellPrev
	segs$logR_Copy_Number <- logRbasedCN(segs[["median"]], purity, ploidy, cellPrev.seg, cn=2)
	if (gender == "male" & length(chrXStr) > 0){ ## analyze chrX separately
		ind.cnChrX <- which(segs$chr == chrXStr)
		segs$logR_Copy_Number[ind.cnChrX] <- logRbasedCN(segs[["median"]][ind.cnChrX], purity, ploidy, cellPrev.seg[ind.cnChrX], cn=1)
	}

	## assign copy number to use - Corrected_Copy_Number
	# 1) same ichorCNA calls for autosomes - initialize to no-change in copy number 
	segs$Corrected_Copy_Number <- as.integer(segs$copy.number)
	segs$Corrected_Call <- segs[[callColName]]

	ind.change <- c()
	if (purity >= minPurityToCorrect){
		# 2) ichorCNA calls adjusted for >= copies - HLAMP
		# perform on all chromosomes
		ind.cn <- which(segs$copy.number >= maxCNtoCorrect.autosomes | 
						(segs$logR_Copy_Number >= maxCNtoCorrect.autosomes * 1.2 & !is.infinite(segs$logR_Copy_Number)))
		segs$Corrected_Copy_Number[ind.cn] <- as.integer(round(segs$logR_Copy_Number[ind.cn]))
		segs$Corrected_Call[ind.cn] <- names[segs$Corrected_Copy_Number[ind.cn] + 1]
		ind.change <- c(ind.change, ind.cn)
		
		# 3) ichorCNA calls adjust for HOMD
		if (correctHOMD){
			ind.cn <- which(segs$chr %in% chrs & 
				(segs$copy.number == 0 | segs$logR_Copy_Number == 1/2^6))
			segs$Corrected_Copy_Number[ind.cn] <- as.integer(round(segs$logR_Copy_Number[ind.cn]))
			segs$Corrected_Call[ind.cn] <- names[segs$Corrected_Copy_Number[ind.cn] + 1]
			ind.change <- c(ind.change, ind.cn)
		}
		# 4) Re-adjust chrX copy number for males (females already handled above)
		if (gender == "male" & length(chrXStr) > 0){
			if (!correctWholeChrXForMales){ # correct all of chrX for males
				ind.cn <- which(segs$chr == chrXStr)
			}else{ # only highest chrX CN
				ind.cn <- which(segs$chr == chrXStr & 
					(segs$copy.number >= maxCNtoCorrect.X | segs$logR_Copy_Number >= maxCNtoCorrect.X * 1.2))
			}
			segs$Corrected_Copy_Number[ind.cn] <- as.integer(round(segs$logR_Copy_Number[ind.cn]))
			segs$Corrected_Call[ind.cn] <- names[segs$Corrected_Copy_Number[ind.cn] + 2]
			ind.change <- c(ind.change, ind.cn)
		}

		# 5) Adjust copy number for inconsistent logR and copy number prediction (e.g. opposite copy number direction)
	    # mostly affects outliers, which are short or single point segments
	    # since chrX for males have all data corrected, it will by default not be included in this anyway
	    # chrX for females are treated as regular diploid chromosomes here
	    ind.seg.oppCNA <- which(((round(segs$logR_Copy_Number) < ploidy & segs$Corrected_Copy_Number > ploidy) | 
	    				 		 (round(segs$logR_Copy_Number) > ploidy & segs$Corrected_Copy_Number < ploidy)) & 
	    				   	 	(abs(round(segs$logR_Copy_Number) - segs$Corrected_Copy_Number) > 2))
	    segs$Corrected_Copy_Number[ind.seg.oppCNA] <- as.integer(round(segs$logR_Copy_Number[ind.seg.oppCNA]))
	    ind.change <- unique(c(ind.change, ind.seg.oppCNA))
	}

	## adjust the bin level data ##
	# 1) assign the original calls
	cn$Corrected_Copy_Number <- as.integer(cn$copy.number)
	cn$Corrected_Call <- cn[[callColName]]
	cellPrev.cn <- rep(1, nrow(cn))
	cellPrev.cn[as.logical(cn$subclone.status)] <- cellPrev
	cn$logR_Copy_Number <- logRbasedCN(cn[["logR"]], purity, ploidy, cellPrev.cn, cn=2)
	if (gender == "male" & length(chrXStr) > 0){ ## analyze chrX separately
		ind.cnChrX <- which(cn$chr == chrXStr)
		cn$logR_Copy_Number[ind.cnChrX] <- logRbasedCN(cn[["logR"]][ind.cnChrX], purity, ploidy, cellPrev.cn[ind.cnChrX], cn=1)
	}
	if (purity >= minPurityToCorrect){
		# 2) correct bins overlapping adjusted segs
		ind.change <- unique(ind.change)
		ind.overlapSegs <- c()
		if (length(ind.change) > 0){		
			cn.gr <- as(cn, "GRanges")
			segs.gr <- as(segs, "GRanges")
			hits <- findOverlaps(query = cn.gr, subject = segs.gr[ind.change])
			cn$Corrected_Copy_Number[queryHits(hits)] <- segs$Corrected_Copy_Number[ind.change][subjectHits(hits)]
			cn$Corrected_Call[queryHits(hits)] <- segs$Corrected_Call[ind.change][subjectHits(hits)]
			ind.overlapSegs <- queryHits(hits)
		}
		# 3) correct bins that are missed as high level amplifications
		ind.hlamp <- which(cn$copy.number >= maxCNtoCorrect.autosomes | 
	 					(cn$logR_Copy_Number >= maxCNtoCorrect.autosomes * 1.2 & !is.infinite(cn$logR_Copy_Number)))
		ind.cn <- unique(ind.hlamp, ind.overlapSegs)
	 	cn$Corrected_Copy_Number[ind.cn] <- as.integer(round(cn$logR_Copy_Number[ind.cn]))
	 	cn$Corrected_Call[ind.cn] <- names[cn$Corrected_Copy_Number[ind.cn] + 1]

	 	#4) Correct bins that are clearly homozygous deletions
		# hetd.median <- median(cn[cn$copy.number == 1, "logR"], na.rm = TRUE)
		# hetd.sd <- sd(cn[cn$copy.number == 1, "logR"], na.rm = TRUE)
		# ind.homd <- which(cn$logR_Copy_Number <= 1/2^6 & cn$logR <= hetd.median - 2 * hetd.sd)
		# cn$Corrected_Copy_Number[ind.homd] <- 0
		# cn$Corrected_Call[ind.homd] <- "HOMD"

	 }
	 
	return(list(cn = cn, segs = segs))
}


## compute copy number using corrected log ratio ##
logRbasedCN <- function(x, purity, ploidyT, cellPrev=NA, cn = 2){
	if (length(cellPrev) == 1 && is.na(cellPrev)){
		cellPrev <- 1
	}else{ #if cellPrev is a vector
		cellPrev[is.na(cellPrev)] <- 1
	}
	ct <- (2^x 
		* (cn * (1 - purity) + purity * ploidyT * (cn / 2)) 
		- (cn * (1 - purity)) 
		- (cn * purity * (1 - cellPrev))) 
	ct <- ct / (purity * cellPrev)
	ct <- sapply(ct, max, 1/2^6)
	return(ct)
}


computeBIC <- function(params){
  iter <- params$iter
  KS <- nrow(params$rho) # num states
  N <- ncol(params$rho) # num data points
  NP <- nrow(params$n) + nrow(params$phi) # normal + ploidy
  L <- 1 # precision (lambda)
  numParams <- KS * (KS - 1) + KS * (L + NP) - 1
  b <- -2 * params$loglik[iter] + numParams * log(N)
  return(b)
} 


#############################################################
## function to compute power from ULP-WGS purity/ploidy #####
#############################################################
# current assumptions: power for clonal heterozygous mutations

