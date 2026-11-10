all: clean search_ucac5

search_ucac5: search_ucac5.c
	gcc -o search_ucac5 search_ucac5.c -lm

clean:
	rm -f search_ucac5
	