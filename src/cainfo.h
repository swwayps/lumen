#pragma once
/* See cainfo.c. Returns a static string, or NULL when nothing was found (in
 * which case libcurl keeps its compiled-in default). */
const char *lumen_ca_file(void);
const char *lumen_ca_dir(void);

/* NULL-terminated probe lists, exposed for tests. */
const char *const *lumen_ca_file_candidates(void);
const char *const *lumen_ca_dir_candidates(void);
