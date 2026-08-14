SUMMARY = "Production programming/flashing helper scripts for STM32MP2 CARGT boards"
DESCRIPTION = "Deploys the production_support scripts (production_program*.py, \
FlashLayout templates, gen_correct_gpt.sh, etc.) into DEPLOY_DIR_IMAGE alongside \
the board's other build artifacts, so they're always available after a build. \
Also bundles a prebuilt Linux fastboot binary (fastboot/Linux/fastboot, AOSP \
platform-tools, Apache-2.0 - see fastboot/Notice.txt) so production_program_uuu.py \
does not depend on a fastboot install on the host running these scripts."

LICENSE = "CLOSED"

SRC_URI = "git://git@gitlab.com/cargt-internal/cargt-yocto/stm32mp2/production_support.git;protocol=ssh;branch=main"
SRCREV = "${AUTOREV}"
PV = "1.0+git${SRCPV}"

S = "${WORKDIR}/git"

inherit deploy

# AUTOREV + shallow git clones mean SRCPV's rev-count prefix doesn't reliably
# increase between fetches, which trips the packagedata QA version-monotonicity
# check across all of this recipe's auto-split packages. Harmless here: this
# recipe is deploy-only and never ships a package to a target rootfs or feed.
ERROR_QA:remove = "version-going-backwards"

do_deploy() {
    # fastboot/ in the shared deploy dir is owned entirely by this recipe
    # (nothing else writes there), so clear out any stale copy left behind
    # by an earlier interrupted/differently-configured build before
    # redeploying - otherwise bitbake refuses to overwrite files it doesn't
    # recognize as belonging to this task's manifest ("trying to install
    # files into a shared area when those files already exist").
    rm -rf ${DEPLOY_DIR_IMAGE}/fastboot

    # The scripts locate their FlashLayout TSVs relative to their own
    # location (flashlayout_cargt-image-dev/...), which Yocto already
    # deploys at the machine deploy dir root - so these must land there
    # too, not in a subdirectory. This also carries along fastboot/Linux/fastboot,
    # which production_program_uuu.py locates the same way (relative to itself).
    cp -a ${S}/. ${DEPLOYDIR}/
    rm -rf ${DEPLOYDIR}/.git
    # scripts/create_sdcard_from_flashlayout.sh is ST's own tool, already
    # deployed by sdcard-raw-tools-native; this repo just bundles a copy.
    rm -rf ${DEPLOYDIR}/scripts
    # cp -a preserves the executable bit from git, but re-assert it: a
    # non-executable fastboot binary would only fail at flash time, on
    # the production line, not at build time.
    chmod 755 ${DEPLOYDIR}/fastboot/Linux/fastboot
}
addtask deploy before do_build after do_compile
