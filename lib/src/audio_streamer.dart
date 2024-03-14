/// audio_streamer.dart
import 'dart:convert';
import 'dart:math';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:audio_streamer/audio_streamer.dart';
import 'package:flutter_project/constants/ZerothDefine.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:permission_handler/permission_handler.dart';

import 'dart:typed_data';
import 'package:web_socket_channel/io.dart';
import 'dart:isolate';

import 'dart:typed_data';
import 'dart:math' as math;

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
  List<double> prevAudio = []; // audio 이전의 버퍼
  List<double> pastAudio = []; // prevAudio 이전의 버퍼
  List<double> audio = []; // 현재 버퍼
  bool isBufferUpdated = false;

  StreamSubscription<List<double>>? audioSubscription;
  DateTime? lastSpokeAt; // 마지막 말한 시점의 시간

  ReceivePort receivePort = ReceivePort(); // 수신 포트 설정
  IOWebSocketChannel? channel; // 웹소켓 채널 객체

  // double? dynamic_energy_adjustment_damping = 0.15;
  // double? dynamic_energy_ratio = 1.5; // 민감도: 높은 값을 잡을 수록 작은 소리에는 오디오 전송을 시작하지 않음
  double? energy_threshold = 0.1;
  double? energy_rest_threshold = 0.15;
  double? energy;
  bool? prevSpeakingState;
  double minBufferSize = ZerothDefine.ZEROTH_RATE_44 / 2;
  double maxBufferSize = 30000;
  double prev_energy = 0;
  double prev_energy_diff = 0;
  double curr_energy_diff = 0;
  double past_energy_diff = 0;
  double curr_energy_diff2 = 0;

  mAudioStreamer() {
    _init();
    receivePort.listen((message) {
      //서버로부터 메시지를 받음
      // 모든 데이터를 받으면 웹소켓 채널을 닫음
      if (message == "END_OF_DATA") {
        // 서버가 모든 데이터를 받았다는 메시지를 받으면
        print("EOD");
        channel?.sink.close(); // 웹소켓 채널 닫음
        audio.clear(); // 오디오 데이터
        prevAudio.clear();
        receivedText.value = List.empty(); // 녹음이 중지되면 서버에서 받아오기 위해 사용했던 변수를 비워줌
      } else {
        // 서버로부터 메시지를 받아 저장
        receivedText.value = List.empty(); // 실시간으로 받아오고 있기 때문에, 받아올 때마다 비워주어야함.
        // print("eod: msg $message");
        receivedText.value = List.from(receivedText.value)..add(message);
      }
    });
  }

  ///오디오 객체 초기화
  Future<void> _init() async {
    _audioStreamer = AudioStreamer();
    prevSpeakingState = false;
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

    prevSpeakingState = false;

    // 샘플링율 - 안드로이드에서만 동작
    _audioStreamer.sampleRate = 44100;

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
    audio.clear();
    // 의미 없는 오디오 조건: 0.5초보다 작은 크기이거나 rms값이 작을 때
    // 현재 오디오 의미 없을 때 이전 오디오만 전송
    if (audio.length < minBufferSize || getRMS(audio) <= 0.05) {
      print("vad: current useless audio.");
      sendAudio(audioBuffer: prevAudio, isFinal: true);
    }
    // 현재 오디오 의미 있을 때 현재 오디오를 전송
    else {
      // print("eod: useful current audio. send prev, current audio");
      print("vad: current meaningful audio.");
      sendAudio(audioBuffer: prevAudio, isFinal: false);
      sendAudio(audioBuffer: audio, isFinal: true);
    }

    audioSubscription?.cancel();
    isBufferUpdated = false;
    lastSpokeAt = null;
    isRecording.value = false;
  }

  /// 오디오 샘플링 콜백
  void onAudio(List<double> buffer) async {
    // 버퍼에 음성 데이터를 추가
    audio.addAll(buffer);

    // 음성 입력 크기 저장
    energy = getRMS(audio);

    updateSpeakingStatus();

    checkSilence();

    // 버퍼가 업데이트 됐다면 prevAudio를 전송
    if (isBufferUpdated) {
      sendAudio(audioBuffer: pastAudio, isFinal: false);
    }

    // 말을 쉬고 있는 중일 때, rms가 일정 값 이상 감소하면 오디오 버퍼 업데이트(말마디 자르기 구현)
    // 현재 audio는 바로 보내지 않고 이전 상태에 저장
    curr_energy_diff = energy! - prev_energy;

    //TODO - energy_rest_threshold 0.15 이상까지 증가했다 떨어지는 시점에 감지
    //TODO - 안 되면 네이티브 코드처럼 바이트 버퍼 사용하기
    if (audio.length > minBufferSize && prevSpeakingState!
        && isSpeaking
        // && past_energy_diff < 0
        && past_energy_diff > prev_energy_diff
        && curr_energy_diff < prev_energy_diff){ // 감소하는 중이면서
        // && ratio < -2) { // 30퍼센트 이하로 감소하면
      // if (prevSpeakingState! && isSpeaking && (curr_energy_diff*(-1))/(prev_energy_diff - curr_energy_diff) < 0.8){
      // if (prevSpeakingState! && isSpeaking && curr_energy_diff < 0.02){
      // if (prevSpeakingState! && isSpeaking){
      // 에너지 변화율이 50% 이하로 떨어지면
      // if (prevSpeakingState! && isSpeaking && prev_energy_diff > 0 && (-curr_energy_diff)/(prev_energy_diff - curr_energy_diff) < 0.16) {

      isBufferUpdated = true;

      pastAudio = List.from(prevAudio);
      prevAudio = List.from(audio);
      print("vad: buffer updated. buffer length: ${audio.length}");

      audio.clear();
    } else {
      isBufferUpdated = false;
    }

    print("vad: isSpeaking $isSpeaking // energy $energy // current_energy_diff $curr_energy_diff");
    // print("vad: curr_energy_diff $curr_energy_diff // prev_energy_diff $prev_energy_diff "
    //     "// ratio ${curr_energy_diff/(prev_energy_diff-curr_energy_diff)}");

    past_energy_diff = prev_energy_diff;
    prev_energy_diff = curr_energy_diff;

    prev_energy = energy!;
  }

  /// 오디오 버퍼를 받아 RMS로 리턴
  double getRMS(List<double> buffer) {
    double sum = 0;
    for (int i = 0; i < buffer.length; i++) {
      sum += buffer[i] * buffer[i];
    }
    sum /= buffer.length;
    return sqrt(sum);
  }

  /// 음성 진폭의 rms에 따라 isSpeaking을 업데이트해주는 메소드
  void updateSpeakingStatus() {
    prevSpeakingState = isSpeaking;
    if (energy! > energy_threshold!) {
      lastSpokeAt = DateTime.now();
      isSpeaking = true;
    } else {
      isSpeaking = false;
    }
  }

  ///침묵을 감지하는 함수
  void checkSilence() {
    if (!isSpeaking &&
        lastSpokeAt != null &&
        DateTime.now().difference(lastSpokeAt!).inSeconds >= 3) {
      stopRecording();
      Fluttertoast.showToast(msg: "침묵이 감지되었습니다.");
      print('vad: silence detected // ${DateTime.now()}');
    }
  }

  ///웹소켓 통신으로 실제로 wav를 isolate로 전송
  void sendAudio({required List<double> audioBuffer, required bool isFinal}) {
    // 원시 오디오 데이터인 PCM을 wav로 변환
    var wavData = transformToWav(audioBuffer);

    // minBufferSize 이상일 때만 전송
    if (audioBuffer.isNotEmpty) {
      // if (audioBuffer.length >= minBufferSize) {
      // print("vad: sendAudio bufferSize ${audioBuffer.length}");

      // 웹소켓을 통해 wav 전송
      Isolate.spawn(sendOverWebSocket, {
        'wavData': wavData,
        'sendPort': receivePort.sendPort,
        'isFinal': isFinal, // 마지막 데이터인지 나타내는 변수 추가
      });
    }
  }

  ///웹소켓 통신 정보를 stream에 추가하고, 서버로부터 응답을 받는 부분
  static void sendOverWebSocket(Map<String, dynamic> args) async {
    final wavData = args['wavData'];
    final sendPort = args['sendPort'];
    final isFinal = args['isFinal'];

    //채널 설정
    final channel = IOWebSocketChannel.connect(ZerothDefine.MY_URL_test);

    //wav 파일을 base64로 인코딩
    var base64WavData = base64Encode(wavData);

    // stream에 데이터를 추가
    channel.sink.add(jsonEncode({
      'wavData': base64WavData,
      'isFinal': isFinal,
    }));

    // 서버로부터의 응답을 받아 메인 Isolate로 전송
    channel.stream.listen((message) {
      sendPort.send(message);
    });
  }

  /// 오디오 PCM을 wav로 바꾸는 함수
  Uint8List transformToWav(List<double> pcmData) {
    int numSamples = pcmData.length;
    int numChannels = ZerothDefine.ZEROTH_MONO;
    int sampleSize = 2; // 16 bits#########

    int byteRate = sampleRate * numChannels * sampleSize;

    var header = ByteData(44);
    var bData = ByteData(numSamples * sampleSize);

    // PCM 데이터를 Int16 형식으로 변환
    for (int i = 0; i < numSamples; ++i) {
      bData.setInt16(
          i * sampleSize, (pcmData[i] * 32767).toInt(), Endian.little);
    }

    // RIFF header
    header.setUint32(0, 0x46464952, Endian.little); // "RIFF"
    header.setUint32(4, 36 + numSamples * sampleSize, Endian.little);
    header.setUint32(8, 0x45564157, Endian.little); // "WAVE"

    // fmt subchunk
    header.setUint32(12, 0x20746D66, Endian.little); // "fmt "
    header.setUint32(16, 16, Endian.little); // SubChunk1Size
    header.setUint16(20, 1, Endian.little); // AudioFormat
    header.setUint16(22, numChannels, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, byteRate, Endian.little);
    header.setUint16(32, numChannels * sampleSize, Endian.little); // BlockAlign
    header.setUint16(34, 8 * sampleSize, Endian.little); // BitsPerSample

    // data subchunk
    header.setUint32(36, 0x61746164, Endian.little); // "data"
    header.setUint32(40, numSamples * sampleSize, Endian.little);

    var wavData = Uint8List(44 + numSamples * sampleSize);
    wavData.setAll(0, header.buffer.asUint8List());
    wavData.setAll(44, bData.buffer.asUint8List());

    return wavData;
  }

  /// 에러 핸들러
  void handleError(Object error) {
    isRecording.value = false; //에러 발생시 녹음 중지
    print(error);
  }
}