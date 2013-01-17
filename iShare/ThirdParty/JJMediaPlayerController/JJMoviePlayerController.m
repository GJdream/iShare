//
//  JJMoviePlayerController.m
//  iShare
//
//  Created by Jin Jin on 12-12-5.
//  Copyright (c) 2012年 Jin Jin. All rights reserved.
//

#import "JJYUVDisplayView.h"
#import "JJMovieAudioPlayer.h"
#import "JJMoviePlayerController.h"
#import "libavformat/avformat.h"
#import "libswscale/swscale.h"
#import "libswresample/swresample.h"

#import <time.h>

#define MAX_AUDIOQ_SIZE (256 * 1024)
#define MAX_VIDEOQ_SIZE (5 * 256 * 1024)

#define VIDEO_PICTURE_QUEUE_SIZE 1

#define VIDEO_FRAME_QUEUE_SIZE 5

#pragma mark - packet queue

typedef struct PacketQueue
{
	AVPacketList *first_pkt, *last_pkt;
	int nb_packets;
	int size;
    __unsafe_unretained NSCondition* cond;
} PacketQueue;

typedef struct VideoPicture
{
	AVPicture *content;
	int width, height; /* source height & width */
	int allocated;
    int64_t pts;
} VideoPicture;

typedef struct AVFrameList
{
    AVFrame frame;
    struct AVFrameList *next;
} AVFrameList;

typedef struct AVFrameQueue
{
    AVFrameList *first_frame, *last_frame;
    int nb_frames;
} AVFrameQueue;

typedef struct VideoState
{
	AVFormatContext *pFormatCtx;
	int             videoStream, audioStream, subtitleStream;

	AVStream        *audio_st;
	PacketQueue     audioq;

	AVStream        *video_st;
	PacketQueue     videoq;
    
    AVStream        *subtitle_st;
    PacketQueue     subtitleq;
    
    AVFrameQueue    videoframeq;
    
	VideoPicture    pictq[VIDEO_PICTURE_QUEUE_SIZE];
	int             pictq_size, pictq_rindex, pictq_windex;
    
	char            filename[1024];
	int             quit;
} VideoState;

//
//void PushEvent(Uint32 type, void* data){
//    SDL_Event event;
//    event.type = type;
//    event.user.data1 = data;
//    SDL_PushEvent(&event);
//}

static int frame_queue_put(AVFrameQueue* q, AVFrame* frame){
    AVFrameList* frameList1 = (AVFrameList*)av_malloc(sizeof(AVFrameList));
    if (!frameList1){
        return -1;
    }
    
    frameList1->frame = *frame;
    frameList1->next = NULL;
    
    if (!q->last_frame){
        q->first_frame = frameList1;
    }else{
        q->last_frame->next = frameList1;
    }
    q->last_frame = frameList1;
    q->nb_frames++;
    
    return 0;
}

static int frame_queue_get(AVFrameQueue* q, AVFrame* frame){
    AVFrameList* flist;
    
    flist = q->first_frame;
    if (flist){
        q->first_frame = flist->next;
        if (!q->first_frame){
            q->last_frame = NULL;
        }
        *frame = flist->frame;
        av_free(flist);
        q->nb_frames--;
        return 0;
    }else{
        return -1;
    }
}

static int packet_queue_put(PacketQueue *q, AVPacket *pkt)
{
	AVPacketList *pkt1;
	if(av_dup_packet(pkt) < 0)
	{
		return -1;
	}
    [q->cond lock];
	pkt1 = (AVPacketList *)av_malloc(sizeof(AVPacketList));
	if (!pkt1)
		return -1;
	pkt1->pkt = *pkt;
	pkt1->next = NULL;
	if (!q->last_pkt)
		q->first_pkt = pkt1;
	else
		q->last_pkt->next = pkt1;
	q->last_pkt = pkt1;
	q->nb_packets++;
	q->size += pkt1->pkt.size;
    [q->cond signal];
    [q->cond unlock];
	return 0;
}

static int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block)
{
	AVPacketList *pkt1;
	int ret;
    [q->cond lock];
	for(;;)
	{
		pkt1 = q->first_pkt;
		if (pkt1)
		{
			q->first_pkt = pkt1->next;
			if (!q->first_pkt)
				q->last_pkt = NULL;
			q->nb_packets--;
			q->size -= pkt1->pkt.size;
			*pkt = pkt1->pkt;
			av_free(pkt1);
			ret = 1;
			break;
		}
		else if (!block)
		{
			ret = 0;
			break;
		}
		else
		{
            [q->cond wait];
		}
	}
    [q->cond unlock];
	return ret;
}

@interface JJMoviePlayerController (){
	AVCodecContext *pVideoCodecCtx;
	AVCodecContext *pAudioCodecCtx;
    AVCodecContext *pSubtitleCodecCtx;
    NSTimeInterval seekTime;
    VideoState      *inputStream;
    
    BOOL _prepared;
    BOOL _videoStartedPlaying;
    
    int64_t _audioCurrentPTS;
    int64_t _audioPacketDuration;
    
    JJMoviePlaybackStatus _status;
}

@property (nonatomic, copy) NSString* streamPath;

@property (nonatomic, strong) UIView* internalView;
@property (nonatomic, strong) UIView* internalBackgroundView;
@property (nonatomic, strong) JJYUVDisplayView* displayView;
@property (nonatomic, strong) JJMovieAudioPlayer* audioPlayer;

@property (nonatomic, readonly) CGFloat outputWidth;
@property (nonatomic, readonly) CGFloat outputHeight;
//condition
@property (nonatomic, strong) NSCondition* pictq_cond;
@property (nonatomic, strong) NSCondition* videoStartedCondition;
@property (nonatomic, strong) NSMutableSet* packetQueueConditions;
@property (nonatomic, strong) NSLock* audioLock;
@property (nonatomic, strong) NSLock* statusLock;

//video thread
@property (nonatomic, strong) NSThread* videoThread;
//audio thread
@property (nonatomic, strong) NSThread* audioThread;
//subtitle thread
@property (nonatomic, strong) NSThread* subtitleThread;
//stream decode thread
@property (nonatomic, strong) NSThread* decodeThread;

@end

@implementation JJMoviePlayerController

/**
 clear queue
 @param nil
 @return nil
 @exception nil
 */
-(void)packet_queue_clear:(PacketQueue*)q{
    AVPacket packet, *pkt = &packet;

    while (packet_queue_get(q, pkt, 0) != 0) {
        av_free_packet(pkt);
    }
}

/**
 update player status
 @param status
 @return nil
 @exception nil
 */
-(void)updatePlayerStatus:(JJMoviePlaybackStatus)status{
    [self.statusLock lock];
    _status = status;
    [self.statusLock unlock];
}

//get current audio played duration
-(float)audioPlayedDuration{
    [self.audioLock lock];
    
    //获取当前buffer中的音频包个数，计算未播放的音频时间
    int queuedbuffer = [self.audioPlayer numberOfQueuedBuffer];
    int64_t bufferedTimebase = queuedbuffer * _audioPacketDuration;
    //计算目前音频播放的大概时间
    int64_t playedTimebase = _audioCurrentPTS - bufferedTimebase;
    playedTimebase = (playedTimebase > 0)?playedTimebase:0;
    double ret = playedTimebase * av_q2d(inputStream->audio_st->time_base);
    
    [self.audioLock unlock];
    
    return ret;
}

-(void)resetAudioDuration{
    [self.audioLock lock];
    _audioCurrentPTS = 0;
    _audioPacketDuration = 0;
    [self.audioLock unlock];
}

#pragma mark - getter and setter
-(JJMoviePlaybackStatus)playerStatus{
    [self.statusLock lock];
    JJMoviePlaybackStatus status = _status;
    [self.statusLock unlock];
    return status;
}

-(CGSize)natrualSize{
    if (pVideoCodecCtx){
        return CGSizeMake(pVideoCodecCtx->width, pVideoCodecCtx->height);
    }else{
        return CGSizeMake(320, 240);
    }
}

-(NSTimeInterval)playableDuration{
    return 1;
}

-(CGFloat)outputHeight{
    return self.displayView.frame.size.height;
}

-(CGFloat)outputWidth{
    return self.displayView.frame.size.width;
}

-(UIView*)view{
    return self.internalView;
}

-(UIView*)backgroundView{
    return self.internalBackgroundView;
}

-(void)dealloc{
    [self ffmpeg_release];
}

/**
 init of JJMoviePlayerController with file path
 @param filePath
 @return id
 @exception nil
 */
-(id)initWithFilepath:(NSString*)filePath{
    self = [super init];
    if (self){
        self.streamPath = filePath;
        //conditions for packet queue
        self.audioLock = [[NSLock alloc] init];
        self.pictq_cond = [[NSCondition alloc] init];
        self.videoStartedCondition = [[NSCondition alloc] init];
        self.packetQueueConditions = [NSMutableSet set];
        
        [self createViews];
        [self createInputStream:self.streamPath];
        
        self.initialPlaybackTime = 0.0;
        self.audioPlayer = [[JJMovieAudioPlayer alloc] init];
    }
    
    return self;
}

/**
 init of JJMoviePlayerController with input stream
 @param input stream
 @return id
 @exception nil
 */
-(id)initWithInputStream:(NSInputStream*)inputStream{
    self = [super init];
    if (self){

    }
    
    return self;
}

-(void)seekTime:(double)seconds {
	AVRational timeBase = inputStream->video_st->time_base;
	int64_t targetFrame = (int64_t)((double)timeBase.den / timeBase.num * seconds);
	avformat_seek_file(inputStream->pFormatCtx, inputStream->videoStream, targetFrame, targetFrame, targetFrame, AVSEEK_FLAG_FRAME);
	avcodec_flush_buffers(pVideoCodecCtx);
    avcodec_flush_buffers(pAudioCodecCtx);
}

#pragma mark - display video
-(void)video_display:(VideoState*)is
{
	VideoPicture *vp = &is->pictq[is->pictq_rindex];
	if(vp->content)
	{   
        YUVVideoPicture picture;
        picture.width = vp->width;
        picture.height = vp->height;
        
        for (int i=0; i<4; i++){
            picture.data[i] = vp->content->data[i];
            picture.linesize[i] = vp->content->linesize[i];
        }
        
        [self.displayView setVideoPicture:&picture];
	}
}

#pragma mark - create views
/**
 create views, including display view, background view and overall view
 @param nil
 @return nil
 @exception nil
 */
-(void)createViews{
    self.internalView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
    self.internalBackgroundView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
    self.displayView = [[JJYUVDisplayView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
    self.internalBackgroundView.backgroundColor = [UIColor blackColor];
    
    self.internalView.clipsToBounds = YES;
    self.internalView.autoresizesSubviews = YES;
    
    self.internalBackgroundView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    self.displayView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    
    [self.internalView addSubview:self.internalBackgroundView];
    [self.internalView addSubview:self.displayView];
    
    self.displayView.hidden = YES;
}

#pragma mark - create input stream
/**
 create input stream
 @param nil
 @return nil
 @exception nil
 */
-(void)createInputStream:(NSString*)filePath{
    inputStream = (VideoState *)av_mallocz(sizeof(VideoState));
    strcpy(inputStream->filename, [filePath cStringUsingEncoding:NSUTF8StringEncoding]);
    DebugLog(@"filename is %@", filePath);
    inputStream->videoStream= -1;
    inputStream->audioStream= -1;
}

#pragma mark - ffmpeg and SDL init/dealloc
/**
 init ffmpeg
 @param nil
 @return success or not
 @exception nil
 */
-(BOOL)ffmpeg_init{
	AVFormatContext *pFormatCtx = NULL;
    
    // Register all formats and codecs
    avcodec_register_all();
    av_register_all();
    
	int video_index = -1;
	int audio_index = -1;
    int subtitle_index = -1;
    
	// Open video file
    if (avformat_open_input(&pFormatCtx, inputStream->filename, NULL, NULL) != 0){
		return NO; // Couldn't open file
    }
    // will interrupt blocking functions if we quit!
    pFormatCtx->interrupt_callback.callback = NULL;
    pFormatCtx->interrupt_callback.opaque = NULL;
    
	inputStream->pFormatCtx = pFormatCtx;
    
	// Retrieve stream information
    if (avformat_find_stream_info(pFormatCtx, NULL) < 0){
        return NO;
    } // Couldn't find stream information
    
	// Dump information about file onto standard error
	av_dump_format(pFormatCtx, 0, inputStream->filename, 0);
    
    // Find the best video stream
    if ((video_index =  av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0)) < 0) {
        av_log(NULL, AV_LOG_ERROR, "Cannot find a video stream in the input file\n");
        return NO;
    }
    
    // Find the best audio stream
    if ((audio_index = av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0)) < 0){
        av_log(NULL, AV_LOG_ERROR, "Cannot find a audio stream in the input file\n");
        return NO;
    }
    
    subtitle_index = av_find_best_stream(pFormatCtx, AVMEDIA_TYPE_SUBTITLE, -1, -1, NULL, 0);
    
	if(audio_index >= 0)
	{
		[self stream_component_open:audio_index];
	}
	if(video_index >= 0)
	{
        [self stream_component_open:video_index];
	}
    if (subtitle_index >= 0){
        [self stream_component_open:subtitle_index];
    }
    
	if(inputStream->videoStream < 0 || inputStream->audioStream < 0)
	{
        return NO;
	}
    
    return YES;
}

//release ffmpeg
-(void)ffmpeg_release{
    // Close the codec
    if (pVideoCodecCtx) avcodec_close(pVideoCodecCtx);
    if (pAudioCodecCtx) avcodec_close(pAudioCodecCtx);
    // Close the video file
    if (inputStream->pFormatCtx) avformat_close_input(&(inputStream->pFormatCtx));
}

#pragma mark - prepare to play
/**
 Getting prepared for playing
 locate to the correct time
 @param nil
 @return nil
 @exception nil
 */
-(BOOL)prepareToPlay{
    //init ffmpeg
    if (_prepared == NO){
        
        [self resetAudioDuration];
        
        if ([self ffmpeg_init] == NO){
            //NSLog(@"ffmpeg or SDL init failed");
            return NO;
        }
        //demux video and audio stream
        //get them ready for play
        [self seekTime:self.initialPlaybackTime];
        //create and run decode thread
        self.decodeThread = [[NSThread alloc] initWithTarget:self selector:@selector(decode_thread) object:nil];
        //start threads
        [self.decodeThread start];
        
        _prepared = YES;
    }
    
    return _prepared;
}

/**
 clean up all environment for play
 @param nil
 @return nil
 @exception nil
 */
-(void)cleanUpPlay{
//    PushEvent(FF_QUIT_EVENT, nil);
    [self.decodeThread cancel];
    [self.videoThread cancel];
}

#pragma mark - play back control
-(void)play{
    if ([self prepareToPlay]){
        //add display view
        self.displayView.hidden = NO;
        //read video/audio/subtitle stream and play
        [self updatePlayerStatus:JJMoviePlaybackStatusPlay];
        [self scheduleRefreshTimer:0.1];
        if ([self.delegate respondsToSelector:@selector(moviePlayerWillStartPlay:)]){
            [self.delegate moviePlayerWillStartPlay:self];
        }
    }
}

-(void)stop{
    [self updatePlayerStatus:JJMoviePlaybackStatusStop];
    //bring background view to th front
    [self.internalView bringSubviewToFront:self.internalBackgroundView];
    //stop audio
    [self.audioPlayer stop];
    //stop all thread
    [self.decodeThread cancel];
    [self.videoThread cancel];
    [self.audioThread cancel];
    [self.subtitleThread cancel];
    while ([self.decodeThread isExecuting] || [self.videoThread isExecuting] || [self.audioThread isExecuting] || [self.subtitleThread isExecuting]) {
        //wait until all thread stopped
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    //clear all queues
    [self packet_queue_clear:&inputStream->videoq];
    [self packet_queue_clear:&inputStream->audioq];
    [self packet_queue_clear:&inputStream->subtitleq];
    //release ffmpeg
    [self ffmpeg_release];
    //clean all queues
    self.initialPlaybackTime = 0.0f;
}

-(void)pause{
    [self updatePlayerStatus:JJMoviePlaybackStatusPause];
}

#pragma mark - refresh timer
-(void)scheduleRefreshTimer:(NSTimeInterval)interval{
    if (self.playerStatus != JJMoviePlaybackStatusPlay){
        //do nothing
        return;
    }
    [NSTimer scheduledTimerWithTimeInterval:interval
                                     target:self
                                   selector:@selector(video_refresh_timer:)
                                   userInfo:nil
                                    repeats:NO];
}

#pragma mark - decode thread loop
-(int)decode_thread
{
    @autoreleasepool {
        VideoState* is = inputStream;
        
        // main decode loop
        while([[NSThread currentThread] isCancelled] == NO)
        {
            @autoreleasepool {
                AVPacket packet, *pkt = &packet;
                
                // seek stuff goes here
                if(is->audioq.size > MAX_AUDIOQ_SIZE ||
                   is->videoq.size > MAX_VIDEOQ_SIZE)
                {
                    [NSThread sleepForTimeInterval:0.01];
                    continue;
                }
                if(av_read_frame(is->pFormatCtx, pkt) < 0)
                {
                    if(is->pFormatCtx->pb->error == 0)
                    {//end of file
                        [NSThread sleepForTimeInterval:0.1]; /* no error; wait for user input */
                        continue;
                    }
                    else
                    {//error
                        break;
                    }
                }
                // Is this a packet from the video stream?
                if(pkt->stream_index == is->videoStream)
                {
//                NSLog(@"put video packet");
                    packet_queue_put(&is->videoq, pkt);
                }
                else if(pkt->stream_index == is->audioStream)
                {
//                NSLog(@"put audio packet");
                    packet_queue_put(&is->audioq, pkt);
                }
                else if(pkt->stream_index == is->subtitleStream){
//                NSLog(@"put subtitle packet");
                    packet_queue_put(&is->subtitleq, pkt);
                }
                else
                {
                    av_free_packet(pkt);
                }
            }
        }
    }
    
    NSLog(@"decode thread finished");
    
    return 0;
}

#pragma mark - video thread
-(int)video_thread{
    int len1, frameFinished = 0;
//    NSTimeInterval time;
    AVFrame frame, *ptrFrame = &frame;
    while([[NSThread currentThread] isCancelled] == NO)
    {
        @autoreleasepool {
            AVPacket pkt1, *packet = &pkt1;
//            DebugLog(@"start getting packets from video queue");
            if(packet_queue_get(&inputStream->videoq, packet, 1) < 0)
            {
                // means we quit getting packets
                DebugLog(@"quit getting packets");
                //缓存帧入队列
                break;
            }
//            DebugLog(@"end getting packets from video queue");
            // Decode video frame
            len1 = avcodec_decode_video2(pVideoCodecCtx, ptrFrame, &frameFinished, packet);
            av_free_packet(packet);
            // Did we get a video frame?
            if(frameFinished)
            {
                frameFinished = 0;
                
                if (ptrFrame->pict_type == AV_PICTURE_TYPE_NONE){
                    //drop empty frame
                    continue;
                }else{
                    if([self queue_picture:inputStream withFrame:ptrFrame] < 0)
                    {
                        DebugLog(@"enqueue failed");
                        break;
                    }
                }
                
            }
        }
    }
	
    NSLog(@"video thread finished");
    
	return 0;
}

#pragma mark - subtitle thread
-(int)subtitle_thread{
    
    AVSubtitle s, *subtitle = &s;
    int finished = 0;
    
    @autoreleasepool {
        while ([[NSThread currentThread] isCancelled] == NO) {
            @autoreleasepool {
                AVPacket pkt1, *packet = &pkt1;
                if(packet_queue_get(&inputStream->subtitleq, packet, 1) < 0)
                {
                    // means we quit getting packets
                    DebugLog(@"quit getting audio packets");
                    break;
                }
                
                if (avcodec_decode_subtitle2(pSubtitleCodecCtx, subtitle, &finished, packet) < 0){
                    continue;
                }
                
                if (finished){
                    NSLog(@"subtitle frame");
                }
                
                av_free_packet(packet);
            }
        }
    }
    
    return 0;
}

#pragma mark - audio thread
-(int)audio_thread{
    @autoreleasepool {
        static CFAbsoluteTime startedTime = -1;
        int len1, frameFinished = 0;
        AVCodecContext* codec = pAudioCodecCtx;
        //caculate sample buffer
        double timebase = av_q2d(inputStream->audio_st->time_base);
        int nb_channels = av_get_channel_layout_nb_channels(AV_CH_LAYOUT_STEREO);
        //只要不是双声道立体声，不是AV_SAMPLE_FMT_U8或者AV_SAMPLE_FMT_S16格式的，都需要重新采样
        BOOL needResample = (codec->channels > nb_channels || !(codec->sample_fmt == AV_SAMPLE_FMT_U8 || codec->sample_fmt == AV_SAMPLE_FMT_S16) );
        int alFormat;
        if (needResample){
            alFormat = AL_FORMAT_STEREO16;
        }else{
            alFormat = [self openALSampleFormatFromCodec:pAudioCodecCtx];
        }
        int avFormat = AV_SAMPLE_FMT_S16;
        int sampleRate = codec->sample_rate;
        //resample context
        //不能改变采样率，不然会有噪音
        SwrContext* ctx = swr_alloc_set_opts(NULL,
                                             AV_CH_LAYOUT_STEREO, avFormat, sampleRate,
                                             codec->channel_layout, codec->sample_fmt, codec->sample_rate, 0, NULL);
        swr_init(ctx);
        
        AVFrame frame, *pFrame = &frame;
        
        while([[NSThread currentThread] isCancelled] == NO)
        {
            @autoreleasepool {
                AVPacket pkt1, *packet = &pkt1;
                if(packet_queue_get(&inputStream->audioq, packet, 1) < 0)
                {
                    // means we quit getting packets
                    DebugLog(@"quit getting audio packets");
                    break;
                }
                // Decode video frame
                len1 = avcodec_decode_audio4(codec, pFrame, &frameFinished, packet);
                if (len1 < 0){
                    continue;
                }
                // Did we get a audio frame?
                //音频解码速度比视频快很多，所以如果一开始就直接播放音频的话，会造成音频提前
                //所以最好在第一帧视频播放的时候开始播放音频
                [self.videoStartedCondition lock];
                while (_videoStartedPlaying == NO){
                    //waiting for the first video frame
                    [self.videoStartedCondition wait];
                }
                [self.videoStartedCondition unlock];
                
                if(frameFinished)
                {
                    if (startedTime < 0){
                        startedTime = CFAbsoluteTimeGetCurrent();
                    }
                    
                    //获取当前frame的播放时间
//                    int64_t framepts = av_frame_get_best_effort_timestamp(pFrame);
                    [self.audioLock lock];
                    _audioPacketDuration = av_frame_get_pkt_duration(pFrame);
                    _audioCurrentPTS = av_frame_get_best_effort_timestamp(pFrame);;
                    [self.audioLock unlock];
                    
                    while ([self.audioPlayer numberOfQueuedBuffer] > 800){
                        //OpenAL单个source中最大的buffer数量不能超过1024
                        //这里将上限设置为800，超过就睡眠半个音频包的时间
                        //如果休眠时间过长，如果在其间发生事件，则无法即使响应
                        [NSThread sleepForTimeInterval:_audioPacketDuration*timebase/2];
                    }
                
                    if (needResample){
                        //对不是双声道或采用平面编码的音频进行重新采样，采样为立体声双声道，采样率不变（消除噪音），packet audio
                        uint8_t *output;
                        int out_samples = av_rescale_rnd(swr_get_delay(ctx, pFrame->sample_rate) +
                                                        pFrame->nb_samples, sampleRate, pFrame->sample_rate, AV_ROUND_UP);
                        av_samples_alloc(&output, NULL, nb_channels, out_samples,
                                         AV_SAMPLE_FMT_S16, 0);
                        out_samples = swr_convert(ctx, &output, out_samples,
                                                  (const uint8_t **)pFrame->data, pFrame->nb_samples);
                        int bufferSize = av_samples_get_buffer_size(NULL, nb_channels, out_samples, avFormat, 0);
                        //send audio data to open al
                        [self.audioPlayer moreData:output
                                            length:bufferSize
                                         frequency:sampleRate
                                            format:alFormat];
                        //drain buffer
                        while( (out_samples = swr_convert(ctx, &output, out_samples,
                                                          NULL, 0)) > 0){
                            [self.audioPlayer moreData:output
                                                length:bufferSize
                                             frequency:sampleRate
                                                format:alFormat];
                        };
                        
                        av_freep(&output);
                    }else{
                        //一般音频直接播放
                        [self.audioPlayer moreData:pFrame->data[0]
                                            length:pFrame->linesize[0]
                                         frequency:pFrame->sample_rate
                                            format:alFormat];
                    }
                    frameFinished = 0;
                }
                av_free_packet(packet);
            }
        }
        
        swr_free(&ctx);
    }
    
    NSLog(@"video thread finished");
	
	return 0;
}

-(int)openALSampleFormatFromCodec:(AVCodecContext*)context{
    int format;
    //play audio
    int channels = context->channels;
    int sample_fmt = context->sample_fmt;
    if (channels == 1){
        format = AL_FORMAT_MONO16;
        if (sample_fmt == AV_SAMPLE_FMT_U8 || sample_fmt == AV_SAMPLE_FMT_U8P){
            format = AL_FORMAT_MONO8;
        }else if (sample_fmt == AV_SAMPLE_FMT_S16 || sample_fmt == AV_SAMPLE_FMT_S16P){
            format = AL_FORMAT_MONO16;
        }
    }else{
        format = AL_FORMAT_STEREO16;
        if (sample_fmt == AV_SAMPLE_FMT_U8 || sample_fmt == AV_SAMPLE_FMT_U8P){
            format = AL_FORMAT_STEREO8;
        }else if (sample_fmt == AV_SAMPLE_FMT_S16 || sample_fmt == AV_SAMPLE_FMT_S16P){
            format = AL_FORMAT_STEREO16;
        }
    }
    
    return format;
}

#pragma mark - open stream
-(int)stream_component_open:(int)stream_index{
	AVFormatContext *pFormatCtx = inputStream->pFormatCtx;
	AVCodecContext *codecCtx;
	AVCodec *codec;
    
	if(stream_index < 0 || stream_index >= pFormatCtx->nb_streams)
	{
		return -1;
	}
    
	// Get a pointer to the codec context for the video stream
	codecCtx = pFormatCtx->streams[stream_index]->codec;
    
	codec = avcodec_find_decoder(codecCtx->codec_id);
    AVDictionary* opt = NULL;
	if(!codec || (avcodec_open2(codecCtx, codec, &opt) < 0))
	{
        NSLog(@"Unsupported codec!");
		return -1;
	}
    
	switch(codecCtx->codec_type)
	{
        case AVMEDIA_TYPE_AUDIO:
            inputStream->audioStream = stream_index;
            inputStream->audio_st = pFormatCtx->streams[stream_index];
            // Get a pointer to the codec context for the audio stream
            pAudioCodecCtx = inputStream->audio_st->codec;
            [self packet_queue_init:&(inputStream->audioq)];
            //start audio thread
            self.audioThread = [[NSThread alloc] initWithTarget:self selector:@selector(audio_thread) object:nil];
            [self.audioThread start];
            break;
        case AVMEDIA_TYPE_VIDEO:
            inputStream->videoStream = stream_index;
            inputStream->video_st = pFormatCtx->streams[stream_index];
            // Get a pointer to the codec context for the video stream
            pVideoCodecCtx = inputStream->video_st->codec;
//            pVideoCodecCtx->lowres = 2;
            [self packet_queue_init:&(inputStream->videoq)];
            //start video decode thread
            self.videoThread = [[NSThread alloc] initWithTarget:self selector:@selector(video_thread) object:nil];
            [self.videoThread start];
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            //init subtitle
            inputStream->subtitleStream = stream_index;
            inputStream->subtitle_st = pFormatCtx->streams[stream_index];
            pSubtitleCodecCtx = inputStream->subtitle_st->codec;
            [self packet_queue_init:&(inputStream->subtitleq)];
            //start subtitle decode
//            self.subtitleThread = [[NSThread alloc] initWithTarget:self selector:@selector(subtitle_thread) object:nil];
//            [self.subtitleThread start];
            break;
        default:
            break;
	}
    
    return 0;
}

-(void)alloc_picture:(VideoState *)is{
	VideoPicture *vp;
    
	vp = &is->pictq[is->pictq_windex];
	if(vp->content)
	{
		// we already have one make another, bigger/smaller
        avpicture_free(vp->content);
	}else{
        vp->content = (AVPicture*)av_mallocz(sizeof(AVPicture));
    }
	
    AVCodecContext* codec = is->video_st->codec;
    avpicture_alloc(vp->content, codec->pix_fmt, codec->width, codec->height);
	vp->width = is->video_st->codec->width;
	vp->height = is->video_st->codec->height;
    [self.pictq_cond lock];
	vp->allocated = 1;
    [self.pictq_cond signal];
    [self.pictq_cond unlock];
}

-(void)video_refresh_timer:(NSTimer*)timer{
	VideoState *is = inputStream;
	VideoPicture *vp;
    
    //用于处理延时的时间间隔
    //如果视频落后，刷新时间减去delta_sync，加快刷新
    //如果视频超前，刷新时间加上delta_sync，减慢刷新
    static double delta_sync = 0.0004;
    static double refresh_time = 0.04;
    
    @autoreleasepool {
        double standard_refresh_time = 0.04;
        if (inputStream->video_st){
            standard_refresh_time = 1 / av_q2d(inputStream->video_st->r_frame_rate);
        }
        
        if(is->video_st)
        {
            if(is->pictq_size == 0)
            {
                [self scheduleRefreshTimer:0.01];
            }
            else
            {
                vp = &is->pictq[is->pictq_rindex];
                //获得当前音频播放时间
                double audioPlayedDuration = [self audioPlayedDuration] + standard_refresh_time;
                //对比当前帧的pts*timebase
                AVRational base = inputStream->video_st->time_base;
                
                double videoPTS = vp->pts * av_q2d(base);
//                DebugLog(@"time difference between audio and video: %.4f", audioPlayedDuration-videoPTS);
                //计算下一帧的刷新时间
                if (audioPlayedDuration > videoPTS){//视频时间落后，需要加快视频刷新
                    if (refresh_time > standard_refresh_time){//如果刷新间隔大于标准间隔
                        refresh_time = standard_refresh_time;//直接改为标准间隔
                    }else{//如果刷新时间小于标准间隔
                        refresh_time = (refresh_time - delta_sync>0)?refresh_time-delta_sync:0;//继续缩短间隔，加快刷新
                    }
                }else{//视频时间超前
                    if (refresh_time < standard_refresh_time){//如果刷新间隔小于标准时间
                        refresh_time = standard_refresh_time;//直接改为标准时间
                    }else{//如果刷新时间大于标准间隔
                        refresh_time += delta_sync;//继续增加刷新间隔，减缓刷新
                    }
                }
                
                [self scheduleRefreshTimer:refresh_time];
                /* show the picture! */
                [self video_display:is];
                
                //single that video is started
                if (_videoStartedPlaying == NO){
                    [self.videoStartedCondition lock];
                    _videoStartedPlaying = YES;
                    [self.videoStartedCondition signal];
                    [self.videoStartedCondition unlock];
                }
                
                [self.pictq_cond lock];
                /* update queue for next picture! */
                if(++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE)
                {
                    is->pictq_rindex = 0;
                }
                is->pictq_size--;
                [self.pictq_cond signal];
                [self.pictq_cond unlock];
            }
        }
        else
        {
            [self scheduleRefreshTimer:0.1];
        }
    }
}

-(void)packet_queue_init:(PacketQueue*)q{
	memset(q, 0, sizeof(PacketQueue));
    NSCondition* condition = [[NSCondition alloc] init];
    [self.packetQueueConditions addObject:condition];
	q->cond = condition;
}

#pragma mark - queue picture
-(int)queue_picture:(VideoState*)is withFrame:(AVFrame*)pFrame{
	//printf("queue_picture called/n");
    //modify
    //queue decoded frame
	VideoPicture *vp;
    
	/* wait until we have space for a new pic */
    [self.pictq_cond lock];
	while(is->pictq_size >= VIDEO_PICTURE_QUEUE_SIZE &&
          !is->quit){
        [self.pictq_cond wait];
	}
    [self.pictq_cond unlock];
    
	if(is->quit){
		return -1;
    }
    
	// windex is set to 0 initially
	vp = &is->pictq[is->pictq_windex];
	
    //add picture data to vp
    //need to modify vp
	/* allocate or resize the buffer! */
	if(!vp->content ||
       vp->width != is->video_st->codec->width ||
       vp->height != is->video_st->codec->height)
	{
        
		vp->allocated = 0;
        //allocate picture
        [self alloc_picture:inputStream];
        
		/* wait until we have a picture allocated */
        [self.pictq_cond lock];
		while(!vp->allocated && !is->quit){
            [self.pictq_cond wait];	//没有得到消息时解锁，得到消息后加锁，和SDL_CondSignal配对使用
		}
        [self.pictq_cond unlock];
		if(is->quit)
		{
			return -1;
		}
	}
	/* We have a place to put our picture on the queue */
    
	if(vp->content)
	{
        av_picture_copy(vp->content, (const AVPicture*)pFrame, is->video_st->codec->pix_fmt, is->video_st->codec->width, is->video_st->codec->height);
        vp->pts = av_frame_get_best_effort_timestamp(pFrame);
        
		/* now we inform our display thread that we have a pic ready */
		if(++is->pictq_windex == VIDEO_PICTURE_QUEUE_SIZE)
		{
			is->pictq_windex = 0;
		}
        [self.pictq_cond lock];
		is->pictq_size++;
        [self.pictq_cond unlock];
	}
	return 0;
}

@end
