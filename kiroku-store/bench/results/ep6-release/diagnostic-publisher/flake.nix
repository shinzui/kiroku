{
  inputs.mp12.url = "git+file:///Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku?dir=bench/mp12-cell&rev=b8ec42d661bb25025adb48d0c80f4a2ccd326365";
  outputs = { mp12, ... }: {
    packages.x86_64-linux.kenshou-head = mp12.packages.x86_64-linux.kenshou-head-stall;
  };
}
