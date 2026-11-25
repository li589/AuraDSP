// Build-time Authenticode publisher pin for elevated setup resume.
// The signing pipeline generates the binary-directory copy with the real
// signer SHA-1 thumbprint. This source-tree fallback intentionally fails
// closed; unsigned development requires AURADSP_SETUP_UNSIGNED_TEST_ONLY.
#pragma once

#define AURADSP_TRUSTED_PUBLISHER_THUMBPRINT L""
