# Clearing the workspace
rm(list = ls())

# Load the necessary libraries
library(doParallel)
library(foreach)
library("readxl")
library(nonlinearICP)
library(CondIndTests)
library(bnlearn)
library(ISLR)
library(tidyr)
library(dplyr)
library(pracma)
library(caret)

# Register the parallel backend
cl <- makeCluster(detectCores() - 1) 
registerDoParallel(cl)
#Input
score_var = "YA_Value"
#Input
score <- as.data.frame(read_excel("G:/Shared drives/VISA 689  Digital Twin/parallelR/Input_CD_Trial.xlsx"))
score <- na.omit(score)

# Convert all columns to numeric
score <- as.data.frame(lapply(score, as.numeric))

# For score
# Normalizing Factors' Value
min_max_df <- data.frame(matrix(ncol = 3, nrow = 0))
colnames(min_max_df) <- c('factor', 'max', 'min')

max_x <- c()
min_x <- c()

for (col in colnames(score)){
  if (col == score_var)
    next
  max_x <- append(max_x, max(score[, col]))
  min_x <- append(min_x, min(score[, col]))
  
}

min_max_norm <- function(x, min_x, max_x) {
  (x - min_x) / (max_x - min_x)
}

factors <- colnames(score)
factors <- factors[factors != score_var]

for (i in 1:length(factors)){
  min_max_df[i, 'factor'] = factors[i]
  min_max_df[i, 'max'] = max_x[i]
  min_max_df[i, 'min'] = min_x[i]
  if (min_x[i] != max_x[i]) {
    score[, factors[i]] = min_max_norm(score[, factors[i]], min_max_df$min[i], min_max_df$max[i])
  }
}

# Defining Blacklist Arcs
black.list <- c()
for (i in 1:length(factors)){
  pair <- c(score_var, factors[i])
  black.list <- c(black.list, pair)
}
black.list = matrix(black.list, ncol = 2, byrow = TRUE)
colnames(black.list) <- c("from", "to")

select.columns <- colnames(score)

tests <- c('cor','mc-cor','smc-cor','zf','mc-zf','smc-zf','mi-g','mc-mi-g','smc-mi-g','mi-g-sh')
alphas <- c(0.001,0.005,0.01,0.05,0.1)

set.seed(42)
trainIndex <- createDataPartition(score$YA_Value, p = 0.8, list = FALSE)
trainData <- score[trainIndex, ]
testData <- score[-trainIndex, ]

calc.rmses <- function(alpha, test) {
  # Developing model
  bn <- pc.stable(trainData, blacklist = black.list, test = test, alpha = alpha, debug = FALSE, undirected = FALSE)
  # List for storing RMSEs for all nodes in the current iteration
  rmses <- c()
  # Iterating through every node to calculate the RMSE
  for (node in select.columns){
    
    ## Determining the Parents and Spouses Boundary of the node
    parents_node = parents(bn, node)
    spouses_node = spouses(bn, node)
    causal_features <- union(parents_node,spouses_node)
    
    if(length(causal_features) == 0) # If no Markov Boundary
      next
    
    ## Creating temporary dataset for Linear Regression
    y <- score[, node]
    X <- score[, causal_features]
    LinRegData <- cbind(y, X)
    
    trainLinRegData <- LinRegData[trainIndex,]
    testLinRegData <- LinRegData[-trainIndex,]
    
    model <- lm(y~., data=as.data.frame(trainLinRegData)) # fit linear regression model based on markov boundary of the node
    
    pred <- predict(model, newdata = as.data.frame(testLinRegData))
    rmse <- sqrt(mean(((testLinRegData[, 1] - pred)^2)))
    if(is.na(rmse))
      next
    
    rmses <- append(rmses, rmse)
  }
  return(mean(rmses))
  
}

flatten_list <- function(lst) {
  result <- list()
  
  for (elem in lst) {
    if (is.list(elem)) {
      result <- c(result, flatten_list(elem))
    } else {
      result <- c(result, elem)
    }
  }
  
  return(result)
}

hyper.parameter.tuning <- function(test) {
  alphas <- c(0.001,0.005,0.01,0.05,0.1)
  rmse.all <- foreach(alpha = alphas, .combine='list', .packages=c("bnlearn", "caret")) %dopar% {
    calc.rmses(alpha, test)
  }
  # Flattening the nested list
  rmse.all <- flatten_list(rmse.all)
  
  return(rmse.all)
}
suppressWarnings({
  final.rmse <- foreach(test = tests, .combine='list', .packages=c("bnlearn", "caret", "doParallel", "foreach")) %dopar% {
    hyper.parameter.tuning(test)
  }
  final.rmse <- flatten_list(final.rmse)
})

performance_df <- c()
rmse.count = 0
for (i in 1:length(tests)){
  for (j in 1:length(alphas)){
    rmse.count = rmse.count + 1
    triple <- c(tests[i], alphas[j], final.rmse[rmse.count])
    performance_df <- c(performance_df, triple)
  }
}

performance_df <- matrix(performance_df, ncol = 3, byrow = TRUE)
colnames(performance_df) <- c("Test", "Alpha", "RMSE")

## Finding row with min RMSE
min_row_index <- which.min(performance_df[, 3])
min_row <- performance_df[min_row_index, ]
test <- min_row$Test
alpha <- min_row$Alpha

bn <- boot.strength(trainData, R = 100, m = nrow(trainData), algorithm = "pc.stable", algorithm.args = list(blacklist = black.list, test=test, alpha = alpha), cluster = cl, debug = FALSE)
avg.diff = averaged.network(bn)
fitted_bn <- bn.fit(avg.diff, data = score)
pred <- predict(fitted_bn, node=score_var, testData)

diff <- testData[score_var] - pred

rmse <- sqrt(mean(diff[[score_var]]^2))
mse <- mean(diff[[score_var]]^2)
mae <- mean(abs(diff[[score_var]]))

parents <- fitted_bn$YA_Value$parents
coeff <- (fitted_bn$YA_Value$coefficients)

results <- c()
for (i in 2:length(coeff)){
  pair <- c(parents[i-1], as.numeric(coeff[i]))
  results <- c(results, pair)
}

results <- matrix(results, ncol=2, byrow=TRUE)
colnames(results) <- c("Variable", "Coefficient")
write.csv(results, file = "G:/Shared drives/VISA 689  Digital Twin/parallelR/PC_Stable_Results_Trial.csv", row.names = FALSE)

# Stop the cluster
stopCluster(cl)
