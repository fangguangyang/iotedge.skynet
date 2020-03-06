COMMONMK = common.mk
ARMV7 = arm_v7
$(ARMV7):
	$(MAKE) all PLAT=$(ARMV7) CXXSTD=c++14 CXXFLAGS=CXX14 -f $(COMMONMK)
clean_$(ARMV7):
	$(MAKE) clean PLAT=$(ARMV7) -f $(COMMONMK)
cleanall_$(ARMV7):
	$(MAKE) cleanall PLAT=$(ARMV7) -f $(COMMONMK)

X8664 = x86_64
$(X8664):
	$(MAKE) all PLAT=$(X8664) CXXSTD=c++17 CXXFLAGS=CXX17 -f $(COMMONMK)
clean_$(X8664):
	$(MAKE) clean PLAT=$(X8664) -f $(COMMONMK)
cleanall_$(X8664):
	$(MAKE) cleanall PLAT=$(X8664) -f $(COMMONMK)
