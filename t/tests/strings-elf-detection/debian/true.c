#include <stdio.h>

static void
hardening_trigger(char *p, int i, void (*f)(char *))
{
    char test[10];
    memcpy(test, p, i);
    f(test);
    printf("%s", test);
}

int
main(void)
{
    printf("hello world\n");
    hardening_trigger(NULL, 0, NULL);
}
