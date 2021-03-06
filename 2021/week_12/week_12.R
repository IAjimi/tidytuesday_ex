# TIDYTUESDAY 2021 WEEK 12
# Exploring tidymodels w/ https://www.tidymodels.org/learn/models/parsnip-ranger-glmnet/
# Predicting metascore

#### SETUP ####
library(tidyverse)
library(tidymodels)

video_games <- readr::read_csv("https://raw.githubusercontent.com/rfordatascience/tidytuesday/master/data/2019/2019-07-30/video_games.csv")
games <- readr::read_csv('https://raw.githubusercontent.com/rfordatascience/tidytuesday/master/data/2021/2021-03-16/games.csv')

#### PRE PROCESSING ####
# Simplify games df
games <- games %>%
  group_by(gamename) %>%
  summarise(
    avg = mean(avg), # avg number of players
    peak = max(peak) # peak number of players
    )

# Add to main df
combined_df <- games %>% 
  rename(game = gamename) %>%
  left_join(video_games, by = c("game")) %>%
  mutate(
    release_date = as.Date(release_date, '%b %d, %Y'),
    ) %>% 
  filter(!is.na(metascore))

# Add developper metrics: size, avg score
dev_score <- combined_df %>%
  group_by(developer) %>%
  summarise(dev_size = n(),
            dev_avg = mean(metascore))

combined_df <- combined_df %>% left_join(dev_score, by = 'developer')

#### EDA ####
# Distribution of scores
combined_df %>%
  group_by(metascore) %>% 
  summarise(n = n()) %>%
  ggplot(aes(metascore, n)) + geom_path()

# Strong relationship between avg score and developer average score
combined_df %>%
  ggplot(aes(metascore, dev_avg)) + 
  geom_point(alpha = 0.5) +
  geom_smooth()

# Probably because most developers only have a few games in sample
combined_df %>% 
  ggplot(aes(dev_size)) + geom_histogram()

# Relationship between score and number of players
# avg, peak have many outliers but average playtime seems to have a more normal distr
combined_df %>% 
  filter(avg < 30000) %>%
  ggplot(aes(metascore, avg)) + 
  geom_point(alpha = 0.5) + 
  geom_smooth()

combined_df %>% 
  ggplot(aes(metascore, peak)) + 
  geom_point(alpha = 0.5) + 
  geom_smooth()

combined_df %>% 
  ggplot(aes(metascore, average_playtime)) + 
  geom_point(alpha = 0.5) + 
  geom_smooth()

# Rel between release date and metascore
combined_df %>% 
  ggplot(aes(release_date, metascore)) + 
  geom_point(alpha = 0.5) + 
  geom_smooth()

#### TIDYMODELS ####
set.seed(123)

combined_df <- combined_df %>% 
  ungroup() %>%
  filter(!is.na(release_date) & !is.na(median_playtime)) %>%
  mutate(price = replace_na(price, mean(price, na.rm = TRUE)))

df_split <- initial_split(combined_df)
train <- training(df_split)
test  <- testing(df_split)
folds <- vfold_cv(train, v = 10)

preds <- c('avg', 'release_date', 'dev_avg', 'average_playtime')

### RANDOM FOREST
rf_defaults <- rand_forest(mode = "regression", trees = 1000)
#rf_bagging <- rand_forest(mode = "regression", mtry = .preds(), trees = 1000) # bagging

rf_xy_fit <- 
  rf_defaults %>%
  set_engine("ranger") %>%
  fit_xy(
    x = train[ , preds],
    y = train$metascore
  )

test_pred_df <- test %>%
  select(game, metascore) %>%
  bind_cols(
    predict(rf_xy_fit, new_data = test[, preds])
  )

test_pred_df %>% slice(1:5)
test_pred_df %>% metrics(truth = metascore, estimate = .pred)

### LM
# pre-processing -- only makes a tiny difference (rmse down to 3.35 from 3.37)
norm_recipe <- 
  recipe(
    metascore ~ release_date + dev_avg, 
    data = train
  ) %>%
  step_other(release_date) %>% 
  step_dummy(all_nominal()) %>%
  step_center(all_predictors()) %>%
  step_scale(all_predictors()) %>%
  prep(training = train, retain = TRUE)

glmn_fit <- 
  linear_reg(penalty = 0.001, mixture = 0.5) %>% 
  set_engine("glmnet") %>%
  fit(metascore ~ ., data = bake(norm_recipe, new_data = NULL))

# process test
test_normalized <- bake(norm_recipe, new_data = test, all_predictors())

### TUNED TREE
tune_spec <- decision_tree(
  cost_complexity = tune(),
  tree_depth = tune(),
  min_n = tune()
) %>%
  set_engine("rpart") %>%
  set_mode("regression")

tree_grid <- grid_regular(cost_complexity(),
                          tree_depth(),
                          min_n(),
                          levels = 5) # will try 5 values for each

tree_wf <- workflow() %>%
  add_model(tune_spec) %>%
  add_formula(metascore ~ avg + peak + price + average_playtime + dev_avg)

tree_res <- 
  tree_wf %>% 
  tune_grid(
    resamples = folds,
    grid = tree_grid
  )

tree_res # list of results by split

tree_res %>% 
  collect_metrics() # aggregating results by .config over all splits 

tree_res %>%
  show_best("rmse") # shows top 5 by metric by default

best_tree <- tree_res %>%
  select_best("rmse") # selects top by rmse

final_wf <- 
  tree_wf %>% 
  finalize_workflow(best_tree) # final workflow

final_tree <- 
  final_wf %>%
  fit(data = train) # final tree, ends up with mostly dev_avg, sometimes peak & average_playtime

#### EVALUATE MODELS ####
# join predictions
test_results <- 
  test_pred_df %>%
  rename(`random forest` = .pred) %>%
  bind_cols(
    predict(glmn_fit, new_data = test_normalized) %>%
      rename(glmnet = .pred)
  ) %>%
  bind_cols(
    predict(final_tree, new_data = test) %>%
      rename(tuned_tree = .pred)
  )

# compare -- glmnet quickest & most accurate
test_results %>% metrics(truth = metascore, estimate = glmnet) 
test_results %>% metrics(truth = metascore, estimate = tuned_tree) 
test_results %>% metrics(truth = metascore, estimate = `random forest`) 

# plot comparison
test_results %>% 
  ungroup() %>%
  select(-game) %>% 
  gather(model, prediction, -metascore) %>% 
  ggplot(aes(x = prediction, y = metascore)) + 
  geom_abline(col = "green", lty = 2) + 
  geom_point(alpha = .4) + 
  facet_wrap(~model) + 
  coord_fixed()

# Looking at errors
test_errors <- test_results %>%
  mutate(
    rf_error = metascore - `random forest`,
    glmnet_error = metascore - glmnet,
    tuned_error = metascore - tuned_tree
    )

test_errors %>%
  arrange(desc(rf_error)) %>%
  head(5)

test_errors %>%
  arrange(desc(rf_error)) %>%
  tail(5)
