#include <R.h>
#include <Rinternals.h>
#include "lmdb.h"

void no_error(int x, const char* str);

const char * scalar_character(SEXP x, const char * name);
int scalar_int(SEXP x, const char * name);
size_t scalar_size(SEXP x, const char * name);
