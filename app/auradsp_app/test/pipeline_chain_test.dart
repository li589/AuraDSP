// pipeline_chain_test.dart —— 管线链路合成（全接线 W3）矩阵钉板。
//
// composeChain 是「切输入/切输出即驱动链路」的合成真相：
// 输入第一次参与合成。此前 composeMode 只看输出、输入纯
// 落盘，真机表现为「切输入无反应、链路靠输出点击带起来、
// 链起来后切什么输入都有声」（2026-11-09/10 项 3/4）。
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String chain(String i, String o) =>
      AudioModes.composeChain(input: i, output: o).name;

  test('WASAPI in + WASAPI out = capture local chain', () {
    expect(chain('wasapi', 'wasapi'), 'capture');
  });

  test('VAIO input always lands on the vaio bridge (except asio out)', () {
    expect(chain('vaio', 'wasapi'), 'vaio');
    expect(chain('vaio', 'vaio'), 'vaio');
    expect(chain('vaio', 'asio_client'), 'asio');
  });

  test('ASIO on either side = asio bridge chain', () {
    expect(chain('asio_driver', 'wasapi'), 'asio');
    expect(chain('asio_driver', 'vaio'), 'asio');
    expect(chain('asio_driver', 'asio_client'), 'asio');
    expect(chain('wasapi', 'asio_client'), 'asio');
  });

  test('WASAPI in + VAIO out falls back to the vaio bridge', () {
    // 桥不接受外源注入：捕获源无法喂 VAIO 桥，合成回桥链
    // （播放器须改投 VAIO 端点，面板指引口径）。
    expect(chain('wasapi', 'vaio'), 'vaio');
  });

  test('unknown/empty values fall back to the vaio bridge', () {
    expect(chain('', ''), 'vaio');
    expect(chain('bogus', 'bogus'), 'vaio');
  });

  test('composeMode stays output-only (bookkeeping unchanged)', () {
    // audioMode 簿记不随链路合成变：capture 链的 audioMode
    // 仍是 vaio，链路是管线类别内的子状态。
    expect(
      AudioModes.composeMode(
        category: AudioModes.categoryPipeline,
        pipelineOut: AudioModes.outputWasapi,
      ),
      'vaio',
    );
  });
}
