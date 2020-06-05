# -*-makefile-*-
#
#------------------------------------------------------------
#
# build scripts for data sets of the
# Tatoeba Translation Challenge
#
# https://github.com/Helsinki-NLP/Tatoeba-Challenge
#------------------------------------------------------------


VERSION = v1


## OPUS home directory and language code conversion tools
## TODO: get rid of some hard-coded paths?

OPUS_HOME    = /projappl/nlpl/data/OPUS
SCRIPTDIR    = scripts
ISO639       = ${HOME}/projappl/ISO639/iso639
GET_ISO_CODE = ${ISO639} -m -k
TOKENIZER    = ${SCRIPTDIR}/moses/tokenizer


## corpora in OPUS used for training
## exclude Tatoeba (= test/dev data), WMT-News (reserve for comparison with other models)
## TODO: do we want to / need toexclude some other data sets?

OPUS_CORPORA    = ${sort ${notdir ${shell find ${OPUS_HOME} -maxdepth 1 -mindepth 1 -type d}}}
EXCLUDE_CORPORA = Tatoeba WMT-News MPC1
TRAIN_CORPORA   = ${filter-out ${EXCLUDE_CORPORA},${OPUS_CORPORA}}


## set additional argument options for opus_read (if it is used)
## e.g. OPUSREAD_ARGS = -a certainty -tr 0.3
## TODO: should we always use opus_read instead of pre-extracted moses-style files?
##       (disadvantage: much slower!)
OPUSREAD_ARGS =


## some more tools and parameters
## - check if there is dedicated scratch space (e.g. on puhti nodes)
## - check if terashuf and pigz are available

ifdef LOCAL_SCRATCH
  TMPDIR = ${LOCAL_SCRATCH}
endif

THREADS ?= 4
SORT = sort -T ${TMPDIR} --parallel=${THREADS}
SHUFFLE = ${shell which terashuf 2>/dev/null}
ifeq (${SHUFFLE},)
  SHUFFLE = ${SORT} --random-sort
endif
GZIP := ${shell which pigz 2>/dev/null}
GZIP ?= gzip


## basic training data filtering pipeline

BASIC_FILTERS = | perl -CS -pe 'tr[\x{9}\x{A}\x{D}\x{20}-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}][]cd;' \
		| perl -CS -pe 's/\&\s*\#\s*160\s*\;/ /g' \
		| perl -pe 's/[\p{C}-[\n\t]]/ /g;' \
		| recode -f utf8..utf16 | recode -f utf16..utf8 \
		| $(TOKENIZER)/deescape-special-chars.perl


## available OPUS languages (IDs in the way they appear in the corpus)
## (skip 'simple' = simple English in Wikipedia in the English data sets)

ifneq (${wildcard opus-langs.txt},)
  OPUS_LANGS = ${filter-out simple,${shell head -1 opus-langs.txt}}
endif

## all languages in the current Tatoeba data set in OPUS

TATOEBA_LANGS = ${sort ${patsubst %.txt.gz,%,${notdir ${wildcard ${OPUS_HOME}/Tatoeba/latest/mono/*.txt.gz}}}}
TATOEBA_PAIRS = ${sort ${patsubst %.xml.gz,%,${notdir ${wildcard ${OPUS_HOME}/Tatoeba/latest/xml/*.xml.gz}}}}


## ISO-639-3 language codes

OPUS_LANGS3    = ${shell ${GET_ISO_CODE} ${OPUS_LANGS}}
TATOEBA_LANGS3 = ${shell ${GET_ISO_CODE} ${TATOEBA_LANGS}}
TATOEBA_PAIRS3 = ${sort ${shell ${SCRIPTDIR}/convert_langpair_codes.pl ${TATOEBA_PAIRS}}}


## all data files we need to produce

DATADIR = data

TRAIN_DATA  = ${patsubst %,${DATADIR}/%/train.id.gz,${TATOEBA_PAIRS3}}
TEST_DATA   = ${patsubst %,${DATADIR}/%/test.id,${TATOEBA_PAIRS3}}
TEST_TSV    = ${patsubst ${DATADIR}/%.id,${DATADIR}/test/%.txt,${wildcard ${DATADIR}/*/test.id}}
DEV_TSV     = ${patsubst ${DATADIR}/%.id,${DATADIR}/dev/%.txt,${wildcard ${DATADIR}/*/dev.id}}



## new lang ID files with normalised codes and script info

NEW_TEST_IDS  = ${patsubst ${DATADIR}/%.ids,${DATADIR}/%.id,${wildcard ${DATADIR}/*/test.ids}}
NEW_DEV_IDS   = ${patsubst ${DATADIR}/%.ids,${DATADIR}/%.id,${wildcard ${DATADIR}/*/dev.ids}}
NEW_TRAIN_IDS = ${patsubst ${DATADIR}/%.ids.gz,${DATADIR}/%.id.gz,${wildcard ${DATADIR}/*/train.ids.gz}}



.PHONY: all testdata traindata test-tsv dev-tsv upload
all: opus-langs.txt
	${MAKE} dev-tsv test-tsv
	${MAKE} Data.md
	${MAKE} subsets

data: ${TEST_DATA} ${TRAIN_DATA}
traindata: ${TRAIN_DATA}
testdata: ${TEST_DATA}
test-tsv: ${TEST_TSV}
dev-tsv: ${DEV_TSV}
upload: ${patsubst %,${DATADIR}/%.done,${TATOEBA_PAIRS3}}


print-languages:
	@echo "${TATOEBA_LANGS3}"

print-langpairs:
	@echo "${TATOEBA_PAIRS3}"

move-diff-langpairs:
	@echo ${filter-out ${TATOEBA_PAIRS3},${shell ls ${DATADIR}}}
	mkdir -p data-wrong
	for d in ${filter-out ${TATOEBA_PAIRS3},${shell ls ${DATADIR}}}; do \
	  mv ${DATADIR}/$$d data-wrong/; \
	done

## list of all languages in OPUS
opus-langs.txt:
	wget -O $@.tmp http://opus.nlpl.eu/opusapi/?languages=true
	grep '",' $@.tmp | tr '",' '  ' | sort | tr "\n" ' ' | sed 's/  */ /g' > $@
	rm -f $@.tmp


## create training data by concatenating all data sets
## using normalized language codes (macro-languages)

${DATADIR}/%/train.id.gz:
	@echo "make train data for ${patsubst ${DATADIR}/%/train.id.gz,%,$@}"
	@rm -f $@.tmp1 $@.tmp2
	@mkdir -p ${dir $@}train.d
	@( l=${patsubst ${DATADIR}/%/train.id.gz,%,$@}; \
	  s=${firstword ${subst -, ,${patsubst ${DATADIR}/%/train.id.gz,%,$@}}}; \
	  t=${lastword ${subst -, ,${patsubst ${DATADIR}/%/train.id.gz,%,$@}}}; \
	  E=`${SCRIPTDIR}/find_opus_langs.pl $$s ${OPUS_LANGS}`; \
	  F=`${SCRIPTDIR}/find_opus_langs.pl $$t ${OPUS_LANGS}`; \
	  for e in $$E; do \
	    for f in $$F; do \
		if [ $$e == $$f ]; then a=$${e}1;b=$${f}2; \
		                   else a=$${e};b=$${f}; fi; \
		for c in ${TRAIN_CORPORA}; do \
		  if [ -e ${OPUS_HOME}/$$c/latest/moses/$$e-$$f.txt.zip ]; then \
		    echo "get all $$c data for $$s-$$t ($$e-$$f)"; \
		    unzip -qq -n -d ${dir $@}train.d ${OPUS_HOME}/$$c/latest/moses/$$e-$$f.txt.zip; \
		    paste ${dir $@}train.d/*.$$a ${dir $@}train.d/*.$$b ${BASIC_FILTERS} |\
		    ${SCRIPTDIR}/bitext-match-lang.py -s $$e -t $$f   > $@.tmp2; \
		    rm -f ${dir $@}train.d/*; \
		  elif [ -e ${OPUS_HOME}/$$c/latest/moses/$$f-$$e.txt.zip ]; then \
		    echo "get all $$c data for $$s-$$t ($$e-$$f)"; \
		    unzip -qq -n -d ${dir $@}train.d ${OPUS_HOME}/$$c/latest/moses/$$f-$$e.txt.zip; \
		    paste ${dir $@}train.d/*.$$a ${dir $@}train.d/*.$$b ${BASIC_FILTERS} |\
		    ${SCRIPTDIR}/bitext-match-lang.py -s $$e -t $$f   > $@.tmp2; \
		    rm -f ${dir $@}train.d/*; \
		  elif 	[ -e ${OPUS_HOME}/$$c/latest/xml/$$e-$$f.xml.gz ] || \
			[ -e ${OPUS_HOME}/$$c/latest/xml/$$f-$$e.xml.gz ]; then \
		    echo "opus-read $$c ($$e-$$f)!"; \
		    opus_read ${OPUSREAD_ARGS} -q -ln -rd ${OPUS_HOME} \
				-d $$c -s $$e -t $$f -wm moses -p raw ${BASIC_FILTERS} |\
		    ${SCRIPTDIR}/bitext-match-lang.py -s $$e -t $$f   > $@.tmp2; \
		  fi; \
		  if [ -e $@.tmp2 ]; then \
		    cut -f1 $@.tmp2 | langscript -3 -l $$e -r -D  > $@.tmp2srcid; \
		    cut -f2 $@.tmp2 | langscript -3 -l $$f -r -D  > $@.tmp2trgid; \
		    paste $@.tmp2srcid $@.tmp2trgid $@.tmp2 | sed "s/^/$$c	/"  >> $@.tmp1; \
		    rm -f $@.tmp2 $@.tmp2srcid $@.tmp2trgid; \
		  fi \
		done \
	    done \
	  done \
	)
	if [ -s $@.tmp1 ]; then \
	  ${SHUFFLE} < $@.tmp1 > $@.tmp2; \
	  cut -f4 $@.tmp2 | ${GZIP} -c > ${dir $@}train.src.gz; \
	  cut -f5 $@.tmp2 | ${GZIP} -c > ${dir $@}train.trg.gz; \
	  cut -f1,2,3 $@.tmp2 | ${GZIP} -c > $@; \
	fi
	rm -f $@.tmp1 $@.tmp2
	rmdir ${dir $@}train.d


#
#		    rm -f ${dir $@}train.d/*; \

## make test and dev data
## split shuffled Tatoeba data

${DATADIR}/%/test.id:
	@echo "make test data for ${patsubst ${DATADIR}/%/test.id,%,$@}"
	@rm -f $@.tmp1 $@.tmp2
	@mkdir -p ${dir $@}test.d
	@( l=${patsubst ${DATADIR}/%/test.id,%,$@}; \
	  s=${firstword ${subst -, ,${patsubst ${DATADIR}/%/test.id,%,$@}}}; \
	  t=${lastword ${subst -, ,${patsubst ${DATADIR}/%/test.id,%,$@}}}; \
	  E=`${SCRIPTDIR}/find_opus_langs.pl $$s ${TATOEBA_LANGS}`; \
	  F=`${SCRIPTDIR}/find_opus_langs.pl $$t ${TATOEBA_LANGS}`; \
	  for e in $$E; do \
	    for f in $$F; do \
		if [ $$e == $$f ]; then a=$${e}1;b=$${f}2; \
		                   else a=$${e};b=$${f}; fi; \
		if [ -e ${OPUS_HOME}/Tatoeba/latest/moses/$$e-$$f.txt.zip ]; then \
		  echo "get all Tatoeba data for $$s-$$t ($$e-$$f)"; \
		  echo "unzip -qq -n -d ${dir $@}test.d ${OPUS_HOME}/Tatoeba/latest/moses/$$e-$$f.txt.zip"; \
		  unzip -qq -n -d ${dir $@}test.d ${OPUS_HOME}/Tatoeba/latest/moses/$$e-$$f.txt.zip; \
		  cat ${dir $@}test.d/*.$$a | langscript -3 -l $$e -r -D > $@.tmp1id; \
		  cat ${dir $@}test.d/*.$$b | langscript -3 -l $$f -r -D  > $@.tmp2id; \
		  paste $@.tmp1id ${dir $@}test.d/*.$$a >> $@.tmp1; \
		  paste $@.tmp2id ${dir $@}test.d/*.$$b >> $@.tmp2; \
		  rm -f $@.tmp1id $@.tmp2id ${dir $@}test.d/*; \
		elif [ -e ${OPUS_HOME}/Tatoeba/latest/moses/$$f-$$e.txt.zip ]; then \
		  echo "get all Tatoeba data for $$s-$$t ($$e-$$f)"; \
		  unzip -qq -n -d ${dir $@}test.d ${OPUS_HOME}/Tatoeba/latest/moses/$$f-$$e.txt.zip; \
		  cat ${dir $@}test.d/*.$$a | langscript -3 -l $$e -r -D > $@.tmp1id; \
		  cat ${dir $@}test.d/*.$$b | langscript -3 -l $$f -r -D > $@.tmp2id; \
		  paste $@.tmp1id ${dir $@}test.d/*.$$a >> $@.tmp1; \
		  paste $@.tmp2id ${dir $@}test.d/*.$$b >> $@.tmp2; \
		  rm -f $@.tmp1id $@.tmp2id ${dir $@}test.d/*; \
		fi \
	    done \
	  done \
	)
	@paste $@.tmp1 $@.tmp2 | shuf > $@.tmp3
	@( d=`cat $@.tmp1 | wc -l `; \
	  if [ $$d -gt 15000 ]; then \
	    head -10000 $@.tmp3 > $@.test; \
	    tail -n +10001 $@.tmp3 > $@.dev; \
	  elif [ $$d -gt 10000 ]; then \
	    head -5000 $@.tmp3 > $@.test; \
	    tail -n +5001 $@.tmp3 > $@.dev; \
	  elif [ $$d -gt 5000 ]; then \
	    head -2500 $@.tmp3 > $@.test; \
	    tail -n +2501 $@.tmp3 > $@.dev; \
	  elif [ $$d -gt 2000 ]; then \
	    head -1000 $@.tmp3 > $@.dev; \
	    tail -n +1001 $@.tmp3 > $@.test; \
	  else \
	    mv $@.tmp3 $@.test; \
	  fi )
	@cut -f1,3 $@.test > $@
	@( s=${firstword ${subst -, ,${patsubst ${DATADIR}/%/test.id,%,$@}}}; \
	   t=${lastword ${subst -, ,${patsubst ${DATADIR}/%/test.id,%,$@}}}; \
	   cut -f2 $@.test > $(dir $@)test.src; \
	   cut -f4 $@.test > $(dir $@)test.trg; )
	@if [ -e $@.dev ]; then \
	   s=${firstword ${subst -, ,${patsubst ${DATADIR}/%/test.id,%,$@}}}; \
	   t=${lastword ${subst -, ,${patsubst ${DATADIR}/%/test.id,%,$@}}}; \
	   cut -f2 $@.dev > $(dir $@)dev.src; \
	   cut -f4 $@.dev > $(dir $@)dev.trg; \
	   cut -f1,3 $@.dev  > $(dir $@)dev.id; \
	fi
	@rmdir ${dir $@}test.d
	@rm -f $@.tmp1 $@.tmp2 $@.tmp3 $@.test $@.dev
	@echo ""


# ####################################################
# ## temporary fix, obsolete now ...
# ####################################################

# ## make the style language IDs
# new_test_ids: ${NEW_TEST_IDS}
# new_dev_ids: ${NEW_DEV_IDS}
# new_train_ids: ${NEW_TRAIN_IDS}


# ## normalise language IDs and detect scripts

# ${DATADIR}/%.id: ${DATADIR}/%.ids
# 	cut -f1 $< > $@.1
# 	cut -f2 $< > $@.2
# 	paste $@.1 $(<:.ids=.src) | langscript -3 -L -r -D > $@.11
# 	paste $@.2 $(<:.ids=.trg) | langscript -3 -L -r -D > $@.22
# 	paste $@.11 $@.22 > $@
# 	rm -f $@.1 $@.2 $@.11 $@.22


# ## create new training data files
# ## - normalized language flags + language scripts
# ## - langid filtering
# ## - basic pre-processing filters

# ${DATADIR}/%.id.gz: ${DATADIR}/%.ids.gz
# 	${GZIP} -cd < $< | cut -f1 > $@.0
# 	${GZIP} -cd < $< | cut -f2 > $@.1
# 	${GZIP} -cd < $< | cut -f3 > $@.2
# 	${GZIP} -cd < $(<:.ids.gz=.src.gz) ${BASIC_FILTERS} > $@.3
# 	${GZIP} -cd < $(<:.ids.gz=.trg.gz) ${BASIC_FILTERS} > $@.4
# 	paste $@.3 $@.4 | ${SCRIPTDIR}/bitext-match-lang.py -f \
# 		-s ${firstword ${subst -, ,${patsubst ${DATADIR}/%/,%,${dir $@}}}} \
# 		-t ${lastword ${subst -, ,${patsubst ${DATADIR}/%/,%,${dir $@}}}} > $@.5
# 	paste $@.5 $@.0 $@.1 $@.2 $@.3 $@.4 | grep '^1' | cut -f2 > $@.00
# 	paste $@.5 $@.0 $@.1 $@.2 $@.3 $@.4 | grep '^1' | cut -f3 > $@.11
# 	paste $@.5 $@.0 $@.1 $@.2 $@.3 $@.4 | grep '^1' | cut -f4 > $@.22
# 	paste $@.5 $@.0 $@.1 $@.2 $@.3 $@.4 | grep '^1' | cut -f5 > $@.33
# 	paste $@.5 $@.0 $@.1 $@.2 $@.3 $@.4 | grep '^1' | cut -f6 > $@.44
# 	paste $@.11 $@.33 | langscript -3 -L -r -D > $@.5
# 	paste $@.22 $@.44 | langscript -3 -L -r -D > $@.6
# 	mv -f $(<:.ids.gz=.src.gz) $(<:.ids.gz=-old.src.gz)
# 	mv -f $(<:.ids.gz=.trg.gz) $(<:.ids.gz=-old.trg.gz)
# 	paste $@.11 $@.22 | ${GZIP} -c >  $(<:.ids.gz=-old.ids.gz)
# 	if [ `cat $@.00 | wc -l` -gt 0 ]; then \
# 	  paste $@.00 $@.5 $@.6 | ${GZIP} -c > $@; \
# 	  ${GZIP} -c < $@.33 > $(<:.ids.gz=.src.gz); \
# 	  ${GZIP} -c < $@.44 > $(<:.ids.gz=.trg.gz); \
# 	fi
# 	rm -f $@.0 $@.1 $@.2 $@.3 $@.4 $@.5 $@.6
# 	rm -f $@.00 $@.11 $@.22 $@.33 $@.44



## tab-separated versions of test and dev data (for github and downloads)

${TEST_TSV}: ${DATADIR}/test/%/test.txt: ${DATADIR}/%/test.id
	mkdir -p ${dir $@}
	paste $< ${<:.id=.src} ${<:.id=.trg} > $@

${DEV_TSV}: ${DATADIR}/dev/%/dev.txt: ${DATADIR}/%/dev.id
	mkdir -p ${dir $@}
	paste $< ${<:.id=.src} ${<:.id=.trg} > $@



DOWNLOADURL = https://object.pouta.csc.fi/Tatoeba-Challenge

## statistics of the data sets
Data.md:
	echo "# Tatoeba Challenge Data" > $@
	echo "" >> $@
	echo "| lang-pair |    test    |    dev     |    train   |" >> $@
	echo "|-----------|------------|------------|------------|" >> $@
	for l in ${TATOEBA_PAIRS3}; do \
	  echo -n "| " >> $@; \
	  echo "$$l" | sed 's/-/ /' | xargs ${ISO639} | \
		sed 's/" "/ - /' | awk '{printf "%30s\n", $$0}' | tr "\"\n" '  ' >> $@; \
	  echo -n "[$$l](${DOWNLOADURL}/$$l.tar)  | " >> $@; \
	  cat data/$$l/test.id | wc -l | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	  echo -n "| " >> $@; \
	  if [ -e data/$$l/dev.id ]; then \
	    cat data/$$l/dev.id | wc -l | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	  else \
	    echo -n "           " >> $@; \
	  fi; \
	  echo -n "| " >> $@; \
	  if [ -e data/$$l/train.id.gz ]; then \
	    ${GZIP} -cd < data/$$l/train.id.gz | wc -l | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	    echo "|" >> $@; \
	  else \
	    echo "           |" >> $@; \
	  fi; \
	done


## extended statistics with word counts
Statisics.md:
	echo "# Tatoeba Challenge Data" > $@
	echo "" >> $@
	echo "| lang-pair |    test    |    dev     |    train   |  train-src |  train-trg |" >> $@
	echo "|-----------|------------|------------|------------|------------|------------|" >> $@
	for l in ${TATOEBA_PAIRS3}; do \
	  echo -n "|  $$l  | " >> $@; \
	  cat data/$$l/test.id | wc -l | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	  echo -n "| " >> $@; \
	  if [ -e data/$$l/dev.id ]; then \
	    cat data/$$l/dev.id | wc -l | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	  else \
	    echo -n "           " >> $@; \
	  fi; \
	  echo -n "| " >> $@; \
	  if [ -e data/$$l/train.id.gz ]; then \
	    ${GZIP} -cd < data/$$l/train.id.gz | wc -l | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	    echo -n "| " >> $@; \
	    ${GZIP} -cd < data/$$l/train.src.gz | wc -w | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	    echo -n "| " >> $@; \
	    ${GZIP} -cd < data/$$l/train.trg.gz | wc -w | awk '{printf "%10s\n", $$0}' | tr "\n" ' ' >> $@; \
	    echo "|" >> $@; \
	  else \
	    echo "           |            |            |" >> $@; \
	    echo "           |" >> $@; \
	  fi; \
	done


.PHONY: subsets
subsets: subsets/insufficient.md \
	subsets/zero.md \
	subsets/lowest.md \
	subsets/lower.md \
	subsets/medium.md \
	subsets/higher.md \
	subsets/highest.md \
	subsets/LessThan1000.md


subsets/%.md: Data.md
	mkdir -p ${dir $@}
	@echo "# Tatoeba Challenge Data - Zero-Shot Language Pairs" > $@
	@echo "" >> $@
	@echo "This is a \"${patsubst subsets/%.md,%,$@}\" sub-set of the Tatoeba data." >> $@
	@echo "Download the data files from the link in the table below." >> $@
	@echo "There is a total of" >> $@
	@echo "" >> $@
	@echo -n "* " >> $@
	${SCRIPTDIR}/divide-data-sets.pl < $< |\
	grep '${patsubst subsets/%.md,%,$@}' |\
	wc -l | tr "\n" ' ' >> $@
	@echo " language pairs in this sub-set" >> $@
	@echo "" >> $@
	@echo "| lang-pair |    test    |    dev     |    train   |" >> $@
	@echo "|-----------|------------|------------|------------|" >> $@
	${SCRIPTDIR}/divide-data-sets.pl < $< |\
	grep '${patsubst subsets/%.md,%,$@}' |\
	sed 's/|[^|]*$$/|/' >> $@


## upload data to ObjectStorage on allas
## - requires a-tools!
##
##   module load allas
##   allas-conf


CSC_PROJECT = project_2003093
APUT_FLAGS = -p ${CSC_PROJECT} --override --nc --skip-filelist

data/%.done: data/%
	a-put ${APUT_FLAGS} -b Tatoeba-Challenge $<
	touch $@

#	swift post Tatoeba-Challenge --read-acl ".r:*"




## fix data that has not been shuffled

SHUFFLED_DATA = ${patsubst ${DATADIR}/%,data-shuffled/%,${wildcard ${DATADIR}/*/train.ids.gz}}

.PHONY: shuffle-all
shuffle-all: ${SHUFFLED_DATA}

data-shuffled/%/train.ids.gz: ${DATADIR}/%/train.ids.gz
	mkdir -p ${dir $@}
	${GZIP} -cd < $< > $@.ids
	${GZIP} -cd < ${dir $<}train.src.gz > $@.src
	${GZIP} -cd < ${dir $<}train.trg.gz > $@.trg
	paste $@.ids $@.src $@.trg | ${SHUFFLE} > $@.shuffled
	cut -f1,2,3 $@.shuffled | ${GZIP} -c > $@
	cut -f4 $@.shuffled | ${GZIP} -c > ${dir $@}train.src.gz
	cut -f5 $@.shuffled | ${GZIP} -c > ${dir $@}train.trg.gz
	rm -f $@.ids $@.src $@.trg $@.shuffled
