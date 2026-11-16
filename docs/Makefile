SRCS = $(wildcard *.txt)
PNGS = $(SRCS:.txt=.png)

# The renderer: AscEE (ascee), Ken's ASCII-art to PNG/SVG generator, from PATH
ASCEE ?= ascee

all: $(PNGS)

%.png: %.txt
	$(ASCEE) -f png $<

info:
	@echo $(PNGS)
