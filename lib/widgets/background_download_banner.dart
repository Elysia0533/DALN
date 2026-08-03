import 'package:flutter/material.dart';
import '../screens/download_manager_screen.dart';
import '../services/offline_download_service.dart';

class BackgroundDownloadBanner extends StatelessWidget {
  const BackgroundDownloadBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: OfflineDownloadService.instance,
      builder: (context, _) {
        final service = OfflineDownloadService.instance;
        if (service.status != DownloadStatus.downloading && service.status != DownloadStatus.error) {
          return const SizedBox.shrink();
        }

        final colorScheme = Theme.of(context).colorScheme;
        final isError = service.status == DownloadStatus.error;
        final progressPct = (service.progress * 100).toInt();

        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Material(
            color: isError ? colorScheme.errorContainer : colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
            elevation: 3,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const DownloadManagerScreen()),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    SizedBox(
                      width: 22,
                      height: 22,
                      child: isError
                          ? Icon(Icons.error_outline_rounded, color: colorScheme.onErrorContainer, size: 22)
                          : CircularProgressIndicator(
                              value: service.progress > 0 ? service.progress : null,
                              strokeWidth: 2.5,
                              color: colorScheme.onPrimaryContainer,
                            ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isError
                                ? 'Lỗi khi tải ngầm (${service.failedCount} chương lỗi)'
                                : 'Đang tải ngầm: ${service.storyTitle.isNotEmpty ? service.storyTitle : "Truyện"}',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: isError ? colorScheme.onErrorContainer : colorScheme.onPrimaryContainer,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            isError
                                ? 'Bấm vào đây để mở trang quản lý và tải lại'
                                : '${service.downloadedCount}/${service.totalChapters} chương ($progressPct%) • Chạm để xem trang quản lý',
                            style: TextStyle(
                              fontSize: 11,
                              color: isError
                                  ? colorScheme.onErrorContainer.withValues(alpha: 0.8)
                                  : colorScheme.onPrimaryContainer.withValues(alpha: 0.8),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: Icon(
                        isError ? Icons.refresh : Icons.stop_circle_outlined,
                        size: 22,
                        color: isError ? colorScheme.onErrorContainer : Colors.red,
                      ),
                      tooltip: isError ? 'Mở trang tải' : 'Hủy tải ngầm',
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(builder: (_) => const DownloadManagerScreen()),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
