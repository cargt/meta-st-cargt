# Only pull in the (private, internal-only) production flashing scripts when
# explicitly opted in via CARGT_PRODUCTION_SUPPORT_ENABLE = "1" in local.conf.
# External customers won't have access to that GitLab repo, so this must stay
# off by default.
EXTRA_IMAGEDEPENDS:append = "${@bb.utils.contains('CARGT_PRODUCTION_SUPPORT_ENABLE', '1', ' production-support', '', d)}"
