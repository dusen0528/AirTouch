#!/usr/bin/env python3
"""Validate local ASO drafts and report supplied aggregates. Never publishes."""
import argparse
import csv
from datetime import date
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_METADATA = ROOT / 'store/metadata/ko-KR.json'


def validate(metadata, ready=False):
    errors = []
    for field, limit in [('name', 30), ('subtitle', 30), ('description', 4000)]:
        value = metadata.get(field)
        if not isinstance(value, str) or not value.strip() or len(value) > limit:
            errors.append(f'{field}: 내용 필요, 최대 {limit}자')
        elif field == 'name' and len(value) < 2:
            errors.append('name: 최소 2자')
    keywords = metadata.get('keywords', '')
    if not isinstance(keywords, str):
        errors.append('keywords: 쉼표로 구분한 문자열 필요')
    else:
        words = keywords.split(',')
        if not keywords or len(keywords) > 100 or len(keywords.encode('utf-8')) > 100:
            errors.append('keywords: 최대 100자·UTF-8 100바이트')
        if any(not word.strip() or word != word.strip() for word in words):
            errors.append('keywords: 빈 항목·쉼표 옆 공백 제거 필요')
        if len(set(word.casefold() for word in words)) != len(words):
            errors.append('keywords: 중복 항목 제거 필요')
    if metadata.get('platform') != 'MAC_OS':
        errors.append('platform: AirTouch의 대상은 MAC_OS')
    if ready:
        for field in ['app_store_id', 'support_url', 'privacy_policy_url']:
            if not metadata.get(field):
                errors.append(f'제출 준비 미완료: {field}')
        errors.extend(f'제출 준비 미완료: {x}' for x in metadata.get('submission_blockers', []))
    return errors


def number(row, key):
    value = row.get(key, '').strip()
    if not value:
        return None
    result = int(value)
    if result < 0:
        raise ValueError(f'{key}: 음수는 사용할 수 없습니다')
    return result


def metrics(path):
    required = {'period_start', 'period_end', 'platform', 'territory', 'source_type',
                'unique_device_impressions', 'total_downloads', 'pre_orders', 'source_reference'}
    with path.open(newline='') as file:
        reader = csv.DictReader(file)
        if not required.issubset(reader.fieldnames or []):
            raise ValueError('집계 CSV 헤더가 템플릿과 일치하지 않습니다')
        rows = list(reader)
    reports = []
    for row in rows:
        if date.fromisoformat(row['period_start']) > date.fromisoformat(row['period_end']):
            raise ValueError('집계 시작일은 종료일보다 늦을 수 없습니다')
        if not row['territory'].strip():
            raise ValueError('집계 국가가 필요합니다')
        if row['platform'] != 'MAC_OS' or row['source_type'] != 'App Store search':
            raise ValueError('Mac App Store search 집계만 별도로 입력해주세요')
        if not row['source_reference'].strip():
            raise ValueError('수치의 출처 파일 또는 참조가 필요합니다')
        impressions = number(row, 'unique_device_impressions')
        downloads = number(row, 'total_downloads')
        preorders = number(row, 'pre_orders')
        rate = None
        if impressions is not None and impressions > 0 and downloads is not None and preorders is not None:
            rate = (downloads + preorders) / impressions * 100
        reports.append({
            'period': [row['period_start'], row['period_end']], 'territory': row['territory'],
            'source_reference': row['source_reference'], 'search_conversion_percent': rate,
            'individual_keyword_conversion': None,
            'note': '검색 경로 집계이며 광고가 포함될 수 있습니다. 개별 검색어 전환율이 아닙니다.'})
    return {'periods': reports, 'status': 'supplied_aggregates' if rows else 'no_data',
            'note': '기간별 고유 노출은 합산하지 않습니다. 미제공 값과 0은 구분합니다.'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['check', 'preview', 'metrics'])
    parser.add_argument('--metadata', type=Path, default=DEFAULT_METADATA)
    parser.add_argument('--ready', action='store_true', help='제출 준비 항목도 검사; 제출하지 않음')
    parser.add_argument('--input', type=Path, help='metrics용 검색 집계 CSV')
    args = parser.parse_args()
    try:
        if args.command == 'metrics':
            if args.input is None:
                parser.error('metrics에는 --input이 필요합니다')
            print(json.dumps(metrics(args.input), ensure_ascii=False, indent=2))
            return 0
        metadata = json.loads(args.metadata.read_text())
        errors = validate(metadata, args.ready)
        if errors:
            print('\n'.join(errors), file=sys.stderr)
            return 1
        if args.command == 'check':
            print(f"문구 형식 통과: 이름 {len(metadata['name'])}/30자, 부제 {len(metadata['subtitle'])}/30자, 키워드 {len(metadata['keywords'].encode('utf-8'))}/100바이트")
            print('로컬 초안 검증입니다. 검색 색인·순위·출시 승인을 확인한 결과가 아닙니다.')
        else:
            print(f"# 등록용 초안 · {metadata['locale']}\n\n공개·제출되지 않은 문구입니다.\n")
            for label, field in [('이름', 'name'), ('부제', 'subtitle'), ('키워드', 'keywords')]:
                print(f"**{label}:** {metadata[field]}\n")
            print(metadata['description'])
            print('\n## 제출 전 확인\n')
            for blocker in metadata.get('submission_blockers', []):
                print(f'- {blocker}')
        return 0
    except (OSError, ValueError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
