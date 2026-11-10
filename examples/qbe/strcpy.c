char *copy_string(char *destination, const char *source)
{
    char *start = destination;
    char byte;
    do {
        byte = *source++;
        *destination++ = byte;
    } while (byte != '\0');
    return start;
}

static const char message[] = "MDMA";
static char buffer[] = "xxxxx!!";

int main(void)
{
    char *result = copy_string(buffer + 1, message);
    if (result != buffer + 1 || buffer[0] != 'x' || buffer[6] != '!')
        return 1;
    for (unsigned i = 0; i < sizeof message; ++i)
        if (result[i] != message[i])
            return 2;
    return 0;
}
