/// audio_streamer.dart
import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_streamer/audio_streamer.dart';
import 'package:flutter_project/constants/waveform_const.dart';
import 'package:flutter_project/constants/zeroth_define.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:permission_handler/permission_handler.dart';

import 'dart:typed_data';
import 'package:web_socket_channel/io.dart';
import 'dart:isolate';

import '../models/waveform_model.dart';

class mAudioStreamer {
  ///proivder 관련 변수
  ValueNotifier<bool> isRecording =
      ValueNotifier<bool>(false); // 오디오 객체를 공유하기 위함, 녹음 중인지에 관한 변수
  final ValueNotifier<List<String>> receivedText = ValueNotifier<List<String>>(
      []); // 서버에서 받은 변수, 여러 줄일 수 있기 때문에 List<String> 타입

  bool isSpeaking = false; // 말하고 있는 중인지

  ///오디오 스트리머 세팅 관련 변수들
  dynamic _audioStreamer; // 오디오스트리머 객체

  int sampleRate = ZerothDefine.ZEROTH_RATE_44; // 샘플링율
  List<double> audio = []; // 현재 버퍼
  // ValueNotifier<List<double>> audioDataNotifier = ValueNotifier([]); // waveform_painter에서 변화를 감지
  ValueNotifier<double> audioDataNotifier =
      ValueNotifier(0.0); // waveform_painter에서 변화를 감지
  double threshold = 0.1; // 침묵 기준 진폭


  StreamSubscription<List<double>>? audioSubscription;
  DateTime? lastSpokeAt; // 마지막 말한 시점의 시간

  ReceivePort receivePort = ReceivePort(); // 수신 포트 설정
  IOWebSocketChannel? channel; // 웹소켓 채널 객체

  final WaveformModel waveformModel = WaveformModel();

  mAudioStreamer() {
    _init();
    receivePort.listen((message) {
      //서버로부터 메시지를 받음
      // 모든 데이터를 받으면 웹소켓 채널을 닫음
      if (message == "END_OF_DATA") {
        // 서버가 모든 데이터를 받았다는 메시지를 받으면
        channel?.sink.close(); // 웹소켓 채널 닫음
        receivedText.value = List.empty(); // 녹음이 중지되면 서버에서 받아오기 위해 사용했던 변수를 비워줌
      } else {
        // 실시간으로 받아오고 있기 때문에, 받아올 때마다 비워주어야함.
        receivedText.value = List.empty();
        receivedText.value = [...receivedText.value, message];
      }
    });
  }

  ///오디오 객체 초기화
  Future<void> _init() async {
    _audioStreamer = AudioStreamer();
  }

  /// 권한이 허용됐는지 체크
  Future<bool> checkPermission() async => await Permission.microphone.isGranted;

  /// 마이크 권한 요청
  Future<void> requestPermission() async =>
      await Permission.microphone.request();

  ///오디오 샘플링 시작
  Future<void> startRecording() async {
    //권한 체크
    if (!(await checkPermission())) {
      await requestPermission();
    }

    // 샘플링율 - 안드로이드에서만 동작
    _audioStreamer.sampleRate = sampleRate;

    // 오디오 스트림 시작
    audioSubscription =
        _audioStreamer.audioStream.listen(onAudio, onError: handleError);

    //마지막 말하는 중이었던 시간 업데이트
    lastSpokeAt = DateTime.now();

    // 녹음중 유무 변수를 업데이트
    isRecording.value = true;
  }

  /// 오디오 샘플링을 멈추고 변수를 초기화
  Future<void> stopRecording() async {
    // 중지버튼을 눌렀을 때만 동작할 것임
    if (audio.reduce(max) > threshold && audio.length > 44100 / 2) {
      sendAudio(isFinal: true);
    }

    audioSubscription?.cancel();
    audio.clear(); // 오디오 데이터
    lastSpokeAt = null;
    isRecording.value = false;

    while (audioDataNotifier.value > 0) {
      // 음성 진폭이 양수면 녹음이 끝난 후 millisecondsPerStep 간격으로 파형을 서서히 감소시키는 로직을 동작시킴
      await Future.delayed(
          const Duration(milliseconds: WaveformConst.MILLISEC_PER_STEP));

      audioDataNotifier.value =
          audioDataNotifier.value * WaveformConst.FADING_SLOPE -
              WaveformConst.FADING_CONST; // stopRecording이 실행되면 파형을 점점 줄임
      if (audioDataNotifier.value < 0)
        audioDataNotifier.value = 0; // 진폭이 음수가 되면 0으로 만들어줌 (음수가 되면 화면에 파형이 그려짐)
    }
  }

  /// 오디오 샘플링 콜백
  void onAudio(List<double> buffer) async {
    // 버퍼에 음성 데이터를 추가
    audio.addAll(buffer);

    // 말마디 감지 로직
    // 일정 버퍼 사이즈를 넘어가면 서버에 wav 파일을 전송
    if (audio.length >= 44100 * 3) {
      sendAudio(isFinal: false);
    }

    double maxAmp = buffer.reduce(max);

    audioDataNotifier.value = maxAmp;

    if (maxAmp > threshold && !isSpeaking) {
      // 말하는 중인지 판단
      isSpeaking = true;
      lastSpokeAt = DateTime.now();
    } else {
      isSpeaking = false;
    }

    checkSilence();
  }

  ///웹소켓 통신으로 실제로 pcm data를 isolate로 전송
  void sendAudio({required bool isFinal}) {
    String base64Data = transformToBase64(audio);

    // 웹소켓을 통해 wav 전송
    Isolate.spawn(sendOverWebSocket, {
      'wavData': base64Data,
      'sendPort': receivePort.sendPort,
      'isFinal': isFinal, // 마지막 데이터인지 나타내는 변수 추가
    });

    // 버퍼를 비워줌
    audio.clear();
  }

  ///웹소켓 통신 정보를 stream에 추가하고, 서버로부터 응답을 받는 부분
  static void sendOverWebSocket(Map<String, dynamic> args) async {
    final wavData = args['wavData'];
    final sendPort = args['sendPort'];
    final isFinal = args['isFinal'];

    //채널 설정
    final channel = IOWebSocketChannel.connect(ZerothDefine.MY_URL_test);

    // stream에 데이터를 추가
    channel.sink.add(jsonEncode({
      'wavData': wavData,
      'isFinal': isFinal,
    }));

    // 서버로부터의 응답을 받아 메인 Isolate로 전송
    channel.stream.listen((message) {
      sendPort.send(message);
    });
  }

  // List<double> 형태의 오디오 버퍼를 받아 base64로 인코딩 해주는 함수
  String transformToBase64(List<double> audio) {
    // double 값을 16비트 정수로 변환하기 위한 ByteData 객체 생성
    ByteData byteData = ByteData(audio.length * 2); // 16비트 정수는 2바이트

    for (int i = 0; i < audio.length; i++) {
      // 각 double 값을 16비트 정수로 변환하여 ByteData에 설정
      // 여기서 double 값이 -1.0에서 1.0 사이 (일반적인 오디오 데이터의 범위)
      int sample = (audio[i] * 32767.0)
          .round()
          .clamp(-32768, 32767); // double을 16비트 정수로 변환
      byteData.setInt16(i * 2, sample, Endian.little);
    }

    Uint8List bytes = byteData.buffer.asUint8List(); // ByteData를 Uint8List로 변환

    return base64Encode(bytes); // Uint8List를 base64로 인코딩
  }

  ///침묵을 감지하는 함수
  void checkSilence() {
    if (!isSpeaking &&
        lastSpokeAt != null &&
        DateTime.now().difference(lastSpokeAt!).inSeconds >= 3) {
      stopRecording();
      Fluttertoast.showToast(msg: "침묵이 감지되었습니다.");
    }
  }

  /// 에러 핸들러
  void handleError(Object error) {
    isRecording.value = false; //에러 발생시 녹음 중지
    print(error);
  }
}
