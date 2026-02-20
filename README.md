# memory-map

A macOS memory map tracker that monitors process memory regions and displays metrics such as fragmentation depth and region distribution

![Memory Map](screenshots/memory-map.png)

## Usage

Build the project:
```bash
zip build
```

Run the program:
```bash
sudo ./zig-out/bin/memory-map <pid>
```

Note: look for the PID of the process you want to monitor using `ps aux | grep <process_name>`
