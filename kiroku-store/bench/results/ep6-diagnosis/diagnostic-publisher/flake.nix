{
  inputs.mp12.url = "git+file:///Users/shinzui/Keikaku/bokuno/kiroku-project/kiroku?dir=bench/mp12-cell&rev=f7273083f1d719ac701500c898152c04dadd5170";
  outputs = { mp12, ... }: {
    packages.x86_64-linux.kenshou-head = mp12.packages.x86_64-linux.kenshou-head-stall;
  };
}
