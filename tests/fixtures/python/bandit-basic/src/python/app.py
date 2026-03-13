def unsafe(user_input):
    return eval(user_input)


if __name__ == "__main__":
    print(unsafe("1 + 1"))
