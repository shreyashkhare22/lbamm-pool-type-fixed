forge coverage --ir-minimum --report lcov

lcov --ignore-errors unused --remove ./lcov.info \
  '*/test/*' \
  '*test*.sol' \
  '*/script/*' \
  '*/mocks/*' \
  '*script/DeployAMM.s.sol' \
  -o ./lcov.info.pruned

genhtml lcov.info.pruned --output-directory coverage

open coverage/index.html