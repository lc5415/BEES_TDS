# Installing and Loading Packages -----------------------------------------
if (!require(xgboost)) install.packages("xgboost")
library(xgboost)
if (!require(readr)) install.packages("readr")
library(readr)
if (!require(stringr)) install.packagaes("stringr")
library(stringr)
if (!require(caret)) install.packages("caret")
library(caret)
if (!require(car)) install.packages("car")
library(car)
if (!require(ROCR)) install.packages("ROCR")
library(ROCR)
# if (!require(arulesViz)) install.packages("arulesViz")
# library(arulesViz)
if (!require(glmnet)) install.packages("glmnet")
library(glmnet)
if (!require(foreign)) install.packages("foreign")
library(foreign)

if (!require(scales)) install.packages("scales")
library(scales)


library(tidyverse)

# for auc calculation
library(ModelMetrics)

# for svm
library(e1071)

cluster = 1
platform = Sys.info()['sysname']
if (platform == 'Linux'){
  save_data = data_folder = "../FULLDATA/preprocessed/"
  save_plots = "../FULLResults/"
} else {
  setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
  save_data = data_folder = "../data/preprocessed/"
  save_plots = "../results/"
}

#Load Data
cov = readRDS(paste0(data_folder,"covProcessed.rds"))
bio = readRDS(paste0(data_folder,"bioImputedKNN.rds"))
snp = readRDS(paste0(data_folder,"snpImputed.rds"))

## Load PRS
# PRS = readRDS(paste0(save_plots, ""))
## Load BHS

# Preparing our Data and selecting features -------------------------------

# One stumbling block when getting started with the xgboost package in R is
# that you can't just pass it a dataframe. The core xgboost function requires data to be a matrix.

#To prepare our data, we have a number of steps we need to complete:
#remove information about the target variable from the training data
#reduce the amount of redundant information
#convert categorical information to a numeric format
#Split dataset into training and testing subsets
#Convert the cleaned dataframe to a Dmatrix


# Remove information about the target variable from the training d --------

#First let's remove the columns that have information on our target variable

#Let's create a new vector with labels - convert the CVD_status factor to an
# integer class starting at 0, as the first class should be 0; picky requirement
cov$CVD_status = as.integer(cov$CVD_status)

cov <- cov %>% # we will leave CVD_stattus in cov and let it be split in the
  # analysis function so that the sampling can be done and order is kept
  select(-c("vit_status","dc_cvd_st","age_cl", "stop","stop_cvd",
            "age_CVD", "cvd_final_icd10", "primary_cause_death_ICD10",
            "cvd_death", "cvd_incident", "cvd_prevalent"))

# Reduce the amount of redundant information ------------------------------

#Finally, I want to remove all the non-numeric variables,
# since a matrix can only hold numeric variables - if you try to create a
# matrix from a dataframe with non-numeric variables in it, it will
# conver them all into NA's and give you some warning messages.

# Luis: we want to keep ordered categorical variables as integers but OneHotEncoding
# on non-ordered categorical variables (e.g. smok_ever, physical activity) only those
# 2 surprisingly

##################################################################
##                       ONE HOT ENCODING                       ##
##################################################################

cov$smok_ever_2 = as.factor(cov$smok_ever_2)
cov$physical_activity_2 = as.factor(cov$physical_activity_2)
cov$gender = as.factor(cov$gender)

onehotvars = dummyVars("~.", data = cov[,c("smok_ever_2","physical_activity_2", "gender")])
onehotvars = data.frame(predict(onehotvars, newdata = cov[,c("smok_ever_2",
                                                             "physical_activity_2",
                                                             "gender")]))
# Delete one hot encoded variables and add the encoded versions
cov = cov %>% select(-c(smok_ever_2,physical_activity_2, gender)) %>% cbind(onehotvars)
# remove onehot vars for memory management
remove(onehotvars)

##################################################################
##                 CHARACTER TO ORDINAL FACTORS                 ##
##################################################################
# Often people should say everything that could be automated should
# This is not the case, your variables should be explored carefully
# and you need to order the variables manually, it gives peace of mind
cov$qual2 = factor(cov$qual2, levels = c("low", "intermediate", "high"), ordered = T)
cov$alcohol_2 = factor(cov$alcohol_2, levels = c("Non-drinker", "Social drinker",
                                             "Moderate drinker", "Daily drinker"), ordered = T)
cov$BMI_5cl_2 = factor(cov$BMI_5cl_2, levels = c("[18.5,25[", "[25,30[",
                                             "[30,40[", ">=40"), ordered = T)
cov$no_cmrbt_cl2 = as.numeric(cov$no_cmrbt_cl2)
cov$no_medicines = as.numeric(cov$no_medicines)

# str(cov)


#################################################################
##                  Function would start here                  ##
#################################################################
Analysis = function(model, data, outcome = 'CVD_status', kfolds = 5, train.proportion = 0.8){

  if (!outcome %in% colnames(data)){
    stop(paste("Column", outcome, "not available in the dataset provided"))
  }

  #reproducibility
  set.seed(1247)
  tr.index = sample(1:nrow(data), size = train.proportion*nrow(data))
  X = dplyr::select(data, -outcome)
  y = dplyr::select(data, outcome)

  y.train = y[tr.index,1]
  X.train = X[tr.index,]

  y.test = y[-tr.index,1]
  X.test = X[-tr.index,]

  ## set up for CV
  folds <- cut(seq(1,nrow(X.train)),breaks=kfolds,labels=FALSE)

  if (model == "xgboost"){
    X.train = data.matrix(X.train)
    X.test = data.matrix(X.test)
    y.train = as.numeric(y.train)
    y.test = as.numeric(y.test)
    train = xgboost::xgb.DMatrix(data = X.train, label= y.train)
    test <- xgboost::xgb.DMatrix(data = X.test, label = y.test)

    xgb.folds = list()
    for (fold.id in 1:kfolds){
      xgb.folds[[length(xgb.folds)+1]] = which(folds==fold.id)
    }

    # nrounds is basically number of trees in forest
    # this is basically a grid search
    best_auc = 0
    best_eta = 0
    best_depth = 0
    best_nround = 0
    for (nround in c(5,10,20)){
      #Apparently one should only tweak nrounds realistically or maybe yes
      # https://www.kaggle.com/c/otto-group-product-classification-challenge/discussion/13053
      # https://stackoverflow.com/questions/35050846/xgboost-in-r-how-does-xgb-cv-pass-the-optimal-parameters-into-xgb-train
      # many other things to optimise: https://rdrr.io/cran/xgboost/man/xgb.train.html
      for (max_depth in c(3,5,10,15)){
        for (eta in c(0.1, 0.5, 1)){

          # if the nfold is too tiny this function may give an error because the dataset
          # fed into the model only contains negative samples aka (controls)

          model.cv = xgboost::xgb.cv(data = train, folds = xgb.folds, nrounds = nround, objective = "binary:logistic",
                                     metrics = list("auc"), eta = eta, max_depth = max_depth, verbose = F)

          if (max(model.cv[["evaluation_log"]][["test_auc_mean"]]) > best_auc){
            best_eta = eta
            best_depth = max_depth
            best_nround = nround
            best_auc = max(model.cv[["evaluation_log"]][["test_auc_mean"]])
          }
        }
      }
    }

    best.model = xgboost::xgb.train(data = train, nrounds = best_nround, objective = "binary:logistic",
                                    eta = best_eta, max_depth = best_depth, eval_metric = "auc")
    prdct = predict(best.model, newdata = test)
    pred.objct <- ROCR::prediction(prdct, getinfo(test,'label'))
    auc = ROCR::performance(pred.objct, "auc")
    perf = ROCR::performance(pred.objct, "tpr", "fpr")
    plot(perf, main = model)
    abline(a = 0, b = 1, lty = 2)
    return(auc@y.values[[1]])

  }

  else if (model == "svm"){
    best_auc = 0
    best_kernel = 0
    best_cost = 0
    iter = 1
    for (kernel in c("linear","radial")){
      for(cost in c(1,5,10,15)){
        ######### CV
        auc.list = c()
        print(paste("Iteration ", as.character(iter)))
        iter = iter + 1
        for (i in 1:5){
          valIndexes <- which(folds==i)
          ValData <- X.train[valIndexes, ]
          nonValData <- X.train[-valIndexes, ]

          ValOutcome = y.train[valIndexes]
          nonValOutcome = y.train[-valIndexes]


          # details for this syntax :
          #  https://stackoverflow.com/questions/9028662/predict-maybe-im-not-understanding-it
          md.svm = e1071::svm(nonValOutcome ~ . , data = data.frame(nonValOutcome, nonValData),
                              kernel = kernel, cost = cost)
          prdct = predict(md.svm, newdata =  ValData)
          pred.objct = ROCR::prediction(prdct, ValOutcome)
          auc = ROCR::performance(pred.objct, "auc")
          auc.list = append(auc.list, auc@y.values[[1]])
        }
        mean.auc = mean(auc.list)
        if (mean.auc>best_auc){
          best_auc = mean.auc
          best_kernel = kernel
          best_cost = cost
        }
      }
    }

    bst.svm = e1071::svm(y.train~., data = data.frame(y.train, X.train),
                         kernel = best_kernel, cost = best_cost)
    print(paste("Best params from training:\n\t kernel: ", best_kernel,
                "\n\t C-value: ", best_cost,
                "\n\t AUC: ", best_auc))
    best.prdct = predict(bst.svm, X.test)
    pred.objct = ROCR::prediction(best.prdct, y.test)
    auc = ROCR::performance(pred.objct, "auc")
    performance = ROCR::performance(pred.objct, "tpr", "fpr")
    plot(performance)
    abline(a = 0, b = 1, lty = 2)
    title(model)
    return(auc@y.values[[1]])
  }

  else if (model == "glm"){
    best_auc = 0
    best_kernel = 0
    best_cost = 0

    X.train = data.matrix(X.train)
    y.train = as.numeric(y.train)

    X.test = data.matrix(X.test)
    y.test = as.numeric(as.matrix(y.test))


    mod.cv = glmnet::cv.glmnet(X.train, y.train, foldid = folds,
                               type.measure = "auc", family = "binomial")

    best.prdct = predict(mod.cv, s = "lambda.1se", newx = X.test)
    pred.objct = ROCR::prediction(best.prdct, y.test)
    auc = ROCR::performance(pred.objct, "auc")
    performance = ROCR::performance(pred.objct, "tpr", "fpr")
    plot(performance)
    abline(a = 0, b = 1, lty = 2)
    title(model)
    return(auc@y.values[[1]])
  }
  else {
    stop("Please input a valid value for model")
  }
}

#################################################################
##                 Set the data to be analysed                 ##
#################################################################
# BIO
CVD.bio = merge(cov[,c("CVD_status", "ID")],bio, by = "ID")
rownames(CVD.bio) = CVD.bio$ID

# LOG BIO
log.CVD.bio = merge(cov[,c("CVD_status", "ID")],
                cbind(ID = bio$ID, log(bio[,-1])),
                by = "ID")
rownames(log.CVD.bio) = log.CVD.bio$ID

# cov no bhs no bs2_all
cov.analysis = cov %>% select(-c(ID, BS2_all))

# COV + Bs2_all
covbs2.analysis = cov %>% select(-ID)

#Bio+Cov (-BS2_all)
cov.bio = merge(cov,bio, by = "ID")
rownames(cov.bio) = cov.bio$ID
cov.bio = cov.bio[,-1]
cov.bio = cov.bio%>% select(-BS2_all)

# COV+best BHS
bestBHS = readRDS(paste0(save_plots, "BHS/ScoresPaper.rds"))
cov.BHS = merge(cov,bestBHS, by = "ID")
rownames(cov.BHS) = cov.BHS$ID
cov.BHS = cov.BHS %>% select(-c(ID, BS2_all))

# Cov + PRS (and BHS)
PRSdf = readRDS(paste0(save_plots, "PRS/PolygenicRiskScore.rds"))
cov.PRS = merge(cov,PRSdf, by = "ID")
rownames(cov.PRS) = cov.BHS$ID
cov.PRS = cov.PRS %>% select(-c(ID)) %>% 
  mutate(PRS = rescale(PRS, to = c(-1,1)))

# COV + PRS (no  BHS)
cov.PRS.noBHS = cov.PRS %>% select(-BS2_all)

# COV + BIO +PRS
cov.bio = merge(cov,bio, by = "ID")
cov.bio.PRS = merge(cov.bio, PRSdf, by="ID")
rownames(cov.bio) = cov.bio$ID
cov.bio.PRS = cov.bio.PRS%>% select(-c(ID,BS2_all)) %>% 
  mutate(PRS = rescale(PRS, to = c(-1,1)))

##################################################################
##                 Run models and store results                 ##
##################################################################

ifelse(!dir.exists(file.path(save_plots, "MLAnalysis/")),
       dir.create(file.path(save_plots, "MLAnalysis/")), FALSE)
save_plots = paste0(save_plots,"MLAnalysis/")

data_to_iterate = list(CVD.bio, log.CVD.bio, covbs2.analysis,
                        cov.analysis, cov.BHS, cov.PRS, 
                        cov.PRS.noBHS, cov.bio.PRS, cov.bio)
datanames = c("Bio", "logBio", "Cov+BS2",
              "Cov", "Cov+BHS(refA)", "Cov+PRS+BS2",
              "Cov+PRS", "Cov+Bio+PRS", "Cov+Bio")
models = c("svm", "xgboost", "glm")

all_combs = expand.grid(1:length(data_to_iterate), models)

########### take in commands #########################
args = commandArgs(trailingOnly = TRUE)

comb_selected = as.numeric(args[1])
print(comb_selected)

data_selected = data_to_iterate[[all_combs[comb_selected, 1]]]
data_selected.name = datanames[all_combs[comb_selected, 1]]
model_selected = all_combs[comb_selected, 2]

t0 = Sys.time()
print(paste("Fitting", data_selected.name,
            "with", model_selected))

auc = Analysis(model_selected, data_selected)
print(Sys.time()-t0)
results = data.frame(data = data_selected.name,
                     model = model_selected, 
                     auc = auc)

ifelse(!dir.exists(file.path(save_plots, "ArrayJob/")),
       dir.create(file.path(save_plots, "ArrayJob/")), FALSE)
save_plots = paste0(save_plots,"ArrayJob/")

saveRDS(results, paste0(save_plots, data_selected.name,"_", model_selected, ".rds"))

