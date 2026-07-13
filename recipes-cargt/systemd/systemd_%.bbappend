FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://81-can1.network \
            file://80-can0.network \
        "

# PACKAGECONFIG[unmanaged-network] = ""

do_install:append () {

    install -d ${D}${sysconfdir}/systemd/network

    # Configure the can networks    
    install -Dm 0644 ${WORKDIR}/80-can0.network ${D}${sysconfdir}/systemd/network/    
    install -Dm 0644 ${WORKDIR}/81-can1.network ${D}${sysconfdir}/systemd/network/    

}

