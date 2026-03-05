import subprocess


def main():
    subprocess.run("echo hello", shell=True, check=False)


if __name__ == "__main__":
    main()
