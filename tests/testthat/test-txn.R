context("transactions")

test_that("methods", {
  expect_object_docs(R6_mdb_txn)
})

test_that("begin/abort", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)

  expect_is(txn, "mdb_txn")
  expect_equal(mode(txn$.ptr), "externalptr")

  expect_identical(txn$.env, env)
  expect_identical(txn$.db, env$.db)
  expect_identical(env$.deps$get(), list(env$.db, txn))

  expect_identical(env$.write_txn, txn$.ptr)
  expect_true(txn$.write)

  expect_identical(txn$.db$id(), 1L)
  expect_identical(txn$id(), 1L)

  expect_identical(txn$stat(), env$stat())

  ptr <- txn$.ptr
  txn$abort()
  rm(txn)
  gc()
  expect_true(is_null_pointer(ptr))

  expect_identical(env$.deps$get(), list(env$.db))
  expect_null(env$.write_txn)

  env$close()
})

test_that("basic use", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  expect_null(txn$put("foo", "bar"))
  expect_identical(txn$get("foo"), "bar")
  txn$commit()

  expect_identical(env$.deps$get(), list(env$.db))
  expect_null(env$.write_txn)

  txn <- env$begin(write = FALSE)
  expect_identical(txn$get("foo"), "bar")
  txn$abort()
})

test_that("concurent read", {
  env <- mdb_env(tempfile())
  w1 <- env$begin(write = TRUE)

  expect_null(w1$put("foo", "bar"))
  expect_identical(w1$get("foo"), "bar")
  w1$commit()

  r1 <- env$begin(write = FALSE)
  expect_identical(r1$get("foo"), "bar")

  w2 <- env$begin(write = TRUE)
  expect_identical(r1$get("foo"), "bar")

  expect_null(w2$put("foo", "xyx"))

  expect_identical(w2$get("foo"), "xyx")
  expect_identical(r1$get("foo"), "bar")

  r2 <- env$begin(write = FALSE)
  expect_identical(r2$get("foo"), "bar")

  w2$commit()
  expect_identical(r1$get("foo"), "bar")
  expect_identical(r2$get("foo"), "bar")

  r3 <- env$begin(write = FALSE)
  expect_identical(r3$get("foo"), "xyx")

  env$close()
})

test_that("get: missing", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)

  expect_null(txn$get("foo", FALSE))
  expect_error(txn$get("foo", TRUE),
               "Key 'foo' not found in database")

  expect_null(txn$put("foo", "bar"))
  expect_identical(txn$get("foo", FALSE), "bar")
  expect_identical(txn$get("foo", TRUE), "bar")

  env$close()
})

test_that("get: string raw handling", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  txn$put("foo", "bar")

  expect_identical(txn$get("foo", as_raw = NULL), "bar")
  expect_identical(txn$get("foo", as_raw = FALSE), "bar")
  expect_identical(txn$get("foo", as_raw = TRUE), charToRaw("bar"))
})

test_that("get: raw raw handling", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)

  bytes <- as.raw(c(1, 51, 0, 242))

  txn$put("foo", bytes)

  expect_identical(txn$get("foo", as_raw = NULL), bytes)
  expect_identical(txn$get("foo", as_raw = TRUE), bytes)
  expect_error(txn$get("foo", as_raw = FALSE),
               "value contains embedded nul bytes; cannot return string")

  p <- txn$get("foo", as_proxy = TRUE)
  expect_identical(p$data(as_raw = NULL), bytes)
  expect_identical(p$data(as_raw = NULL), bytes)
})

test_that("get: raw key", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)

  key <- as.raw(c(1, 51, 0, 242))
  value <- "hello world"
  expect_error(txn$get(key), "Key not found in database")
  expect_null(txn$get(key, FALSE))

  p <- txn$get(key, missing_is_error = FALSE, as_proxy = TRUE)
  expect_is(p, "mdb_val_proxy")
  expect_null(p$data())
  expect_identical(p$size(), 0L)

  txn$put(key, value)
  expect_false(p$is_valid())
  expect_error(p$data(),
               "mdb_val_proxy is invalid: transaction has modified database")
  expect_error(p$size(),
               "mdb_val_proxy is invalid: transaction has modified database")

  p <- txn$get(key, as_proxy = TRUE)
  expect_is(p, "mdb_val_proxy")
  expect_identical(p$data(), value)
  expect_identical(p$size(), nchar(value))

  ## These are all done twice to stamp out possible corner cases:
  expect_identical(p$data(FALSE), value)
  expect_identical(p$data(FALSE), value)
  expect_identical(p$data(NULL), value)
  expect_identical(p$data(NULL), value)
  expect_identical(p$data(TRUE), charToRaw(value))
  expect_identical(p$data(TRUE), charToRaw(value))

  ## And again, but with different values first, to deal with how this
  ## is constructed.
  p <- txn$get(key, as_proxy = TRUE)
  expect_identical(p$data(TRUE), charToRaw(value))
  expect_identical(p$data(TRUE), charToRaw(value))
  expect_identical(p$data(FALSE), value)
  expect_identical(p$data(NULL), value)

  txn$put(key, key)
  expect_false(p$is_valid())
  expect_error(p$data(),
               "mdb_val_proxy is invalid: transaction has modified database")
  expect_error(p$size(),
               "mdb_val_proxy is invalid: transaction has modified database")

  p <- txn$get(key, as_proxy = TRUE)
  expect_error(p$data(FALSE),
               "value contains embedded nul bytes; cannot return string")
  expect_identical(p$size(), length(key))
  expect_identical(p$data(), key)
  expect_identical(p$data(TRUE), key)
})

test_that("get: proxy", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)

  value <- "bar"
  expect_null(txn$put("foo", value))

  p1 <- txn$get("foo", as_proxy = TRUE)
  expect_is(p1, "mdb_val_proxy")
  expect_identical(p1$size(), 3L)
  expect_identical(p1$data(), value)
  expect_identical(p1$data(TRUE), charToRaw(value))
  expect_true(p1$is_valid())

  ## Let's do an update which should invalidate the proxy:
  txn$put("another", "key")
  expect_false(p1$is_valid())
  expect_error(p1$data(),
               "mdb_val_proxy is invalid: transaction has modified database")

  ## Then again:
  p2 <- txn$get("another", as_proxy = TRUE)
  expect_identical(p2$data(), "key")

  ## But this time we invalidate the transaction:
  txn$commit()

  expect_false(p2$is_valid())
  expect_error(p2$data(),
               "mdb_val_proxy is invalid: transaction has been closed")
})

test_that("transaction caching", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  txn$commit()
  expect_identical(env$.spare_txns$get(), list())

  txn <- env$begin(write = FALSE)
  txn_ptr <- txn$.ptr

  expect_equal(txn$get("g"), "G")
  txn$abort()

  expect_identical(env$.spare_txns$get(), list(txn_ptr))
  expect_null(txn$.ptr)
  expect_error(txn$get("a"), "txn has been cleaned up")

  txn2 <- env$begin(write = FALSE)
  expect_identical(env$.spare_txns$get(), list())
  expect_identical(txn2$.ptr, txn_ptr)
  expect_equal(txn2$get("g"), "G")

  txn2$abort(FALSE)
  expect_identical(env$.spare_txns$get(), list())
  expect_true(is_null_pointer(txn_ptr))
})

test_that("del", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  expect_true(txn$del("a"))
  expect_false(txn$del("a"))
  env$close()
})

test_that("del: with value", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  expect_error(txn$del("a", "A"),
               "'value' is not allowed for databases with dupsort = FALSE",
               fixed = TRUE)
})

test_that("exists", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  expect_true(txn$exists("a"))
  expect_false(txn$exists("A"))

  expect_identical(txn$exists(character(0)), logical(0))
  expect_identical(txn$exists(letters), rep(TRUE, length(letters)))
  env$close()
})

test_that("replace", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  expect_equal(txn$replace("g", "giraffe"), "G")
  expect_equal(txn$get("g"), "giraffe")
})

test_that("pop", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  expect_equal(txn$pop("g"), "G")
  expect_null(txn$pop("g"))
})

test_that("cmp", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = FALSE)

  expect_identical(txn$cmp("a", "b"), -1L)
  expect_identical(txn$cmp("b", "a"),  1L)
  expect_identical(txn$cmp("a", "a"),  0L)

  expect_error(txn$dcmp("a", "b"),
               "dcmp() is not meaningful on database with dupsort = FALSE",
               fixed = TRUE)
})

test_that("drop; invalidate as we go", {
  env <- mdb_env(tempfile(), maxdbs = 10)
  db2 <- env$open_database("foo")
  expect_identical(db2$id(), 2L)

  txn <- env$begin(db = db2, write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  txn$commit()

  txn_read <- env$begin(db = db2)
  expect_identical(txn_read$get("a"), "A")
  cur <- txn_read$cursor()
  cur$move_to("g")
  p <- cur$value(as_proxy = TRUE)

  env$drop_database(db2)

  expect_false(p$is_valid())
  expect_null(cur$.ptr)
  expect_null(txn_read$.ptr)
  expect_null(db2$.ptr)
  expect_error(cur$first(), "cursor has been cleaned up; can't use!")
  expect_error(txn_read$cursor(), "txn has been cleaned up; can't use!")
  expect_error(db2$id(), "dbi has been cleaned up; can't use")

  expect_identical(env$.deps$get(), list(env$.db))
  expect_null(txn_read$.deps)

  expect_error(env$open_database("foo", create = FALSE),
               "MDB_NOTFOUND")
})

test_that("drop but no delete", {
  env <- mdb_env(tempfile(), maxdbs = 10)
  db2 <- env$open_database("foo")

  expect_identical(db2$id(), 2L)

  txn <- env$begin(db = db2, write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  txn$commit()

  txn_read <- env$begin(db = db2)
  expect_identical(txn_read$get("a"), "A")
  cur <- txn_read$cursor()
  cur$move_to("g")
  p <- cur$value(as_proxy = TRUE)

  env$drop_database(db2, FALSE)

  expect_false(p$is_valid())
  expect_null(cur$.ptr)
  expect_null(txn_read$.ptr)
  expect_null(db2$.ptr)
  expect_error(cur$first(), "cursor has been cleaned up; can't use!")
  expect_error(txn_read$cursor(), "txn has been cleaned up; can't use!")
  expect_error(db2$id(), "dbi has been cleaned up; can't use")

  db3 <- env$open_database("foo", create = FALSE)
  txn_read2 <- env$begin(db = db3)
  expect_null(txn_read2$get("a", FALSE))
})

test_that("drop; root database", {
  env <- mdb_env(tempfile(), maxdbs = 10)
  db <- env$open_database()
  expect_error(env$drop_database(db), "Can't delete root database")
})

test_that("drop; other environment's database", {
  env1 <- mdb_env(tempfile(), maxdbs = 10)
  env2 <- mdb_env(tempfile(), maxdbs = 10)
  db1 <- env1$open_database("foo")
  db2 <- env2$open_database("foo")
  expect_error(env2$drop_database(db1),
               "this is not our database")
})

test_that("serialisation does not crash", {
  env <- mdb_env(tempfile())
  txn <- env$begin()
  expect_false(is_null_pointer(txn$.ptr))
  txn2 <- unserialize(serialize(txn, NULL))
  expect_true(is_null_pointer(txn2$.ptr))
  expect_error(txn2$id(), "txn has been freed; can't use")
})

test_that("with_new_txn", {
  env <- mdb_env(tempfile())
  expect_error(with_new_txn(env, TRUE, function(t) stop("banana")), "banana")
  expect_null(env$.write_txn)
  txn <- env$begin(write = TRUE)
  expect_error(with_new_txn(env, TRUE, function(t) 1),
               "Write transaction is already active for this environment")
  txn$put("a", "apple")
  txn$commit()
  txn <- env$begin(write = TRUE)
  db_ptr <- env$.db$.ptr
  expect_equal(with_new_txn(env, FALSE, function(t)
    mdb_get(t, db_ptr, "a", FALSE, FALSE, FALSE)), "apple")
  expect_error(with_new_txn(env, FALSE, function(t) stop("banana")), "banana")
})

test_that("list", {
  env <- mdb_env(tempfile())

  txn <- env$begin(write = TRUE)
  cur <- txn$cursor()
  expect_identical(thor_list(cur$.ptr, NULL, FALSE, 10L), character(0))

  for (i in letters) {
    txn$put(i, toupper(i))
  }

  expect_identical(txn$list(as_raw = FALSE), letters)
  expect_identical(txn$list(as_raw = TRUE), lapply(letters, charToRaw))
  expect_identical(txn$list(as_raw = NULL), as.list(letters))

  txn$abort()

  ## Then with some raw bytes:
  v <- as.list(letters)
  v[[15]] <- c(charToRaw(v[[15]]), as.raw(c(0, 255, 6)))
  txn <- env$begin(write = TRUE)
  for (i in v) {
    txn$put(i, i)
  }

  cur <- txn$cursor()
  vv <- lapply(v, function(x) if (is.raw(x)) x else charToRaw(x))

  expect_identical(txn$list(as_raw = TRUE), vv)
  expect_identical(txn$list(as_raw = NULL), v)
  expect_error(txn$list(),
               "value contains embedded nul bytes; cannot return string")
})

test_that("list & filter", {
  env <- mdb_env(tempfile())

  txn <- env$begin(write = TRUE)
  cur <- txn$cursor()

  txn$put("apple", "1")
  txn$put("ape", "1")
  txn$put("avocado", "1")
  txn$put("banana", "1")
  txn$put("pear", "1")

  expect_identical(txn$list("a"), c("ape", "apple", "avocado"))
  expect_identical(txn$list("ap"), c("ape", "apple"))
  expect_identical(txn$list("app"), "apple")
  expect_identical(txn$list("b"), "banana")
  expect_identical(txn$list("c"), character(0))
  expect_identical(txn$list(""), c("ape", "apple", "avocado", "banana", "pear"))

  ## More esoteric options:
  expect_identical(txn$list("a", size = 1L), c("ape", "apple", "avocado"))
  expect_identical(txn$list("a", size = 10L), c("ape", "apple", "avocado"))
  expect_identical(txn$list("a", as_raw = TRUE, size = 1L),
                   lapply(c("ape", "apple", "avocado"), charToRaw))
  expect_identical(txn$list("a", as_raw = TRUE, size = 10L),
                   lapply(c("ape", "apple", "avocado"), charToRaw))
  expect_identical(txn$list("a", as_raw = NULL, size = 1L),
                   as.list(c("ape", "apple", "avocado")))
  expect_identical(txn$list("a", as_raw = NULL, size = 10L),
                   as.list(c("ape", "apple", "avocado")))
})

test_that("mget", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  txn$commit()
  txn <- env$begin(write = FALSE)

  ## as_raw = NULL
  expect_identical(txn$mget(character(0)), list())
  expect_identical(txn$mget("a"), list("A"))
  expect_identical(txn$mget(c("a", "b")), list("A", "B"))
  expect_identical(txn$mget(c("a", "xyz", "b")), list("A", NULL, "B"))

  ## as_raw = FALSE
  expect_identical(txn$mget(character(0), as_raw = FALSE), character(0))
  expect_identical(txn$mget("a", as_raw = FALSE), "A")
  expect_identical(txn$mget(c("a", "b"), as_raw = FALSE), c("A", "B"))
  expect_identical(txn$mget(c("a", "xyz", "b"), as_raw = FALSE), c("A", "", "B"))
  ## TODO: decide if "" or NA is better to return in this case.

  ## as_proxy = TRUE
  expect_identical(txn$mget(character(0), as_proxy = TRUE), list())

  p <- txn$mget("a", as_proxy = TRUE)
  expect_is(p, "list")
  expect_equal(lapply(p, function(el) el$data()), list("A"))

  p <- txn$mget(c("a", "b"), as_proxy = TRUE)
  expect_is(p, "list")
  expect_equal(lapply(p, function(el) el$data()), list("A", "B"))

  p <- txn$mget(c("a", "xyz", "b"), as_proxy = TRUE)
  expect_is(p, "list")
  expect_equal(lapply(p, function(el) el$data()), list("A", NULL, "B"))
})

test_that("mget: raw keys", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  for (i in letters) {
    txn$put(i, toupper(i))
  }
  txn$commit()
  txn <- env$begin(write = FALSE)

  expect_equal(txn$mget(charToRaw("a")), list("A"))
  expect_equal(txn$mget(charToRaw("abc")), list(NULL))
  expect_equal(txn$mget(as.list(charToRaw("abc"))), list("A", "B", "C"))
})

test_that("mget: invalid input", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  expect_error(txn$mget(1), "Invalid type; expected a character or raw vector")
})

test_that("mput: basic", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  expect_null(txn$mput(character(0), character(0)))
  expect_null(txn$mput(letters, LETTERS))
  expect_identical(txn$mget(letters, as_raw = FALSE), LETTERS)
})

test_that("mput: lengths", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)

  expect_error(txn$mput("a", letters),
               "Expected 1 values but recieved 26")
  expect_error(txn$mput("a", as.list(letters)),
               "Expected 1 values but recieved 26")
  expect_error(txn$mput(list("a"), letters),
               "Expected 1 values but recieved 26")
  expect_error(txn$mput(list(charToRaw("a")), letters),
               "Expected 1 values but recieved 26")
  expect_error(txn$mput(charToRaw(paste(letters, collapse = "")), letters),
               "Expected 1 values but recieved 26")
})

test_that("mput: atomicity", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  ## Test that a failure part way along the extraction causes the
  ## entire insertion to fail atomically.
  v1 <- letters[1:5]
  v2 <- c(letters[c(6:10, 4, 11:20)])
  txn$mput(v1, toupper(v1))
  expect_error(txn$mput(v2, v2, overwrite = FALSE), "MDB_KEYEXIST")
  expect_identical(txn$mget(v1, as_raw = FALSE), toupper(v1))
  cmp <- txn$mget(v2, as_raw = FALSE)
  expect_identical(cmp, ifelse(v2 %in% v1, toupper(v2), ""))
})

test_that("mdel", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  txn$mput(letters, LETTERS)

  expect_identical(txn$mdel(letters), rep(TRUE, length(letters)))
  expect_identical(txn$mdel(letters), rep(FALSE, length(letters)))
  expect_identical(txn$mdel(character(0)), logical(0))
  expect_identical(txn$mdel(list()), logical(0))

  v <- sample(letters, 12)
  txn$mput(v, toupper(v))
  expect_identical(txn$mdel(letters), letters %in% v)

  expect_error(txn$mdel(letters, "a"),
               "'value' is not allowed for databases with dupsort = FALSE")
})

test_that("mdel: atomic", {
  env <- mdb_env(tempfile())
  txn <- env$begin(write = TRUE)
  txn$mput(letters, LETTERS)
  v <- c(letters[1:5], "", letters[6:10])
  expect_error(txn$mdel(v), "MDB_BAD_VALSIZE")
  expect_identical(txn$mget(letters, as_raw = FALSE), LETTERS)
})

test_that("format", {
  env <- mdb_env(tempfile())
  txn <- env$begin()
  str <- format(txn)
  expect_false(grepl("initialze", str))
  expect_true(grepl("<mdb_txn>", str, fixed = TRUE))
  expect_true(grepl("cursor", str, fixed = TRUE))
})
